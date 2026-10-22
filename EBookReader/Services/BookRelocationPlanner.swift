import Foundation

/// Works out what a batch of watched-folder file events means for the library.
///
/// A book's identity is its row UUID, not its path: annotations, collection
/// memberships, reading position and embeddings all reference `book.id` with
/// ON DELETE CASCADE. So a renamed or moved book file keeps its row (only the
/// path changes), and a file that disappears keeps its row too — the UI shows
/// it as missing until the user deletes it explicitly. Nothing here deletes.
enum BookRelocationPlanner {

    struct Plan: Equatable, Sendable {
        /// Existing books whose file now lives at a new path.
        var relocations: [Relocation] = []
        /// Book files that match no existing book — import these as new books.
        var imports: [String] = []
        /// Books whose file disappeared and wasn't found elsewhere. Kept, not deleted.
        var missing: [UUID] = []
        /// Books whose file is back at its recorded path (e.g. Put Back from the Trash).
        var reappeared: [UUID] = []
    }

    struct Relocation: Equatable, Sendable {
        let bookID: UUID
        let newPath: String
        let fileSize: Int64
    }

    /// A book file at a path that no book row points to.
    struct AppearedFile: Equatable, Sendable {
        let path: String
        let fileSize: Int64
        let format: BookFormat
        /// The file's inode, when known.
        let fileID: UInt64?
    }

    /// A book row whose file is no longer at its recorded path.
    struct MissingBook: Equatable, Sendable {
        let book: Book
        /// Inodes FSEvents reported for the book's old path in this batch.
        let eventFileIDs: Set<UInt64>
        /// True when this batch had an event for the book's old path.
        let reportedInBatch: Bool
    }

    // MARK: - Planning

    static func plan(
        for events: [FileEvent],
        repository: BookRepository,
        fileManager: FileManager = .default
    ) async -> Plan {
        // One entry per book-file path, keeping every inode reported for it.
        var orderedPaths: [String] = []
        var fileIDsByPath: [String: Set<UInt64>] = [:]
        for event in events {
            let url = URL(fileURLWithPath: event.path)
            // Hidden files (e.g. AppleDouble "._book.pdf") are skipped, as FolderScanner does.
            guard FileTypeDetector.isSupportedBookFile(url),
                  !url.lastPathComponent.hasPrefix(".") else { continue }
            if fileIDsByPath[event.path] == nil {
                orderedPaths.append(event.path)
                fileIDsByPath[event.path] = []
            }
            if let fileID = event.fileID {
                fileIDsByPath[event.path]?.insert(fileID)
            }
        }

        var plan = Plan()
        var appeared: [AppearedFile] = []
        var missingByID: [UUID: MissingBook] = [:]
        var presentBooks: [Book] = []

        for path in orderedPaths {
            let existing = try? await repository.fetchBook(byPath: path)
            if let attributes = try? fileManager.attributesOfItem(atPath: path) {
                if let existing {
                    presentBooks.append(existing)
                    continue
                }
                guard attributes[.type] as? FileAttributeType == .typeRegular,
                      let format = FileTypeDetector.detectFormat(from: URL(fileURLWithPath: path))
                else { continue }
                let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
                appeared.append(AppearedFile(
                    path: path,
                    fileSize: (attributes[.size] as? NSNumber)?.int64Value ?? 0,
                    format: format,
                    fileID: inode ?? fileIDsByPath[path]?.first
                ))
            } else if let existing {
                missingByID[existing.id] = MissingBook(
                    book: existing,
                    eventFileIDs: fileIDsByPath[path] ?? [],
                    reportedInBatch: true
                )
                plan.missing.append(existing.id)
            }
        }

        // Books that went missing in an earlier batch (or whose event went to
        // another folder's stream) can still be matched by size and format.
        // Skip rows whose folder is gone too — most likely an unmounted
        // volume, not a moved file.
        if !appeared.isEmpty {
            let sizes = Set(appeared.map(\.fileSize))
            let candidates = (try? await repository.fetchBooks(withFileSizes: sizes)) ?? []
            for book in candidates where missingByID[book.id] == nil {
                let folder = (book.filePath as NSString).deletingLastPathComponent
                guard !fileManager.fileExists(atPath: book.filePath),
                      fileManager.fileExists(atPath: folder) else { continue }
                missingByID[book.id] = MissingBook(book: book, eventFileIDs: [], reportedInBatch: false)
            }
        }

        // A case-only rename ("dune.epub" → "Dune.epub") on a case-insensitive
        // volume: the old path still resolves to the same file, so the book
        // never looks missing. Match it by inode instead.
        var caseRenames: [Relocation] = []
        for book in presentBooks {
            let inode = (try? fileManager.attributesOfItem(atPath: book.filePath))
                .flatMap { ($0[.systemFileNumber] as? NSNumber)?.uint64Value }
            guard let inode,
                  let file = appeared.first(where: {
                      $0.fileID == inode
                          && $0.path != book.filePath
                          && $0.path.compare(book.filePath, options: .caseInsensitive) == .orderedSame
                  }),
                  !caseRenames.contains(where: { $0.newPath == file.path })
            else { continue }
            caseRenames.append(Relocation(bookID: book.id, newPath: file.path, fileSize: file.fileSize))
        }
        let caseRenamedPaths = Set(caseRenames.map(\.newPath))

        plan.relocations = caseRenames + match(
            appeared: appeared.filter { !caseRenamedPaths.contains($0.path) },
            missing: Array(missingByID.values)
        )
        let relocatedPaths = Set(plan.relocations.map(\.newPath))
        let relocatedIDs = Set(plan.relocations.map(\.bookID))
        plan.imports = appeared.map(\.path).filter { !relocatedPaths.contains($0) }
        plan.missing.removeAll { relocatedIDs.contains($0) }
        plan.reappeared = presentBooks.map(\.id).filter { !relocatedIDs.contains($0) }
        return plan
    }

    // MARK: - Matching

    /// Pairs appeared files with missing books, strongest evidence first.
    /// Within a tier a file and a book are only paired when each is the
    /// other's sole candidate — an ambiguous case is imported as a new book
    /// rather than guessed (the missing row stays, so nothing is lost).
    static func match(appeared: [AppearedFile], missing: [MissingBook]) -> [Relocation] {
        typealias Tier = (AppearedFile, MissingBook) -> Bool
        let tiers: [Tier] = [
            // Same inode FSEvents reported for the old path: renamed or moved.
            { file, candidate in
                file.fileID.map { candidate.eventFileIDs.contains($0) } ?? false
            },
            // Same name, size and format in another folder: moved.
            { file, candidate in
                isSameShape(file, candidate)
                    && (file.path as NSString).lastPathComponent == candidate.book.fileName
            },
            // Same size and format, old path vanished in this batch: renamed.
            { file, candidate in
                isSameShape(file, candidate) && candidate.reportedInBatch
            },
            // Same size and format in the same folder: renamed, halves split across batches.
            { file, candidate in
                isSameShape(file, candidate)
                    && (file.path as NSString).deletingLastPathComponent
                        == (candidate.book.filePath as NSString).deletingLastPathComponent
            },
        ]

        // Index candidates so a large batch isn't appeared × missing per tier.
        var byFileID: [UInt64: [MissingBook]] = [:]
        var byShape: [ShapeKey: [MissingBook]] = [:]
        for candidate in missing {
            for fileID in candidate.eventFileIDs {
                byFileID[fileID, default: []].append(candidate)
            }
            byShape[ShapeKey(candidate.book.format, candidate.book.fileSize), default: []].append(candidate)
        }

        var matchedBookByPath: [String: UUID] = [:]
        var claimedBooks = Set<UUID>()

        for tier in tiers {
            var pairs: [(path: String, bookID: UUID)] = []
            for file in appeared where matchedBookByPath[file.path] == nil {
                var seen = Set<UUID>()
                let nearby = (file.fileID.flatMap { byFileID[$0] } ?? [])
                    + (byShape[ShapeKey(file.format, file.fileSize)] ?? [])
                for candidate in nearby {
                    guard !claimedBooks.contains(candidate.book.id),
                          seen.insert(candidate.book.id).inserted,
                          tier(file, candidate) else { continue }
                    pairs.append((file.path, candidate.book.id))
                }
            }
            let pairsPerFile = Dictionary(grouping: pairs, by: \.path).mapValues(\.count)
            let pairsPerBook = Dictionary(grouping: pairs, by: \.bookID).mapValues(\.count)
            for pair in pairs where pairsPerFile[pair.path] == 1 && pairsPerBook[pair.bookID] == 1 {
                matchedBookByPath[pair.path] = pair.bookID
                claimedBooks.insert(pair.bookID)
            }
        }

        return appeared.compactMap { file in
            matchedBookByPath[file.path].map {
                Relocation(bookID: $0, newPath: file.path, fileSize: file.fileSize)
            }
        }
    }

    // MARK: - Applying

    /// Points each relocated book at its new path, keeping the row and all
    /// its user data. Returns the relocations that were applied.
    @discardableResult
    static func applyRelocations(_ plan: Plan, repository: BookRepository) async -> [Relocation] {
        var applied: [Relocation] = []
        for relocation in plan.relocations {
            let updated = (try? await repository.relocateBook(
                id: relocation.bookID,
                toPath: relocation.newPath,
                fileSize: relocation.fileSize
            )) ?? false
            if updated { applied.append(relocation) }
        }
        return applied
    }

    // MARK: - Helpers

    private struct ShapeKey: Hashable {
        let format: BookFormat
        let fileSize: Int64
        init(_ format: BookFormat, _ fileSize: Int64) {
            self.format = format
            self.fileSize = fileSize
        }
    }

    private static func isSameShape(_ file: AppearedFile, _ candidate: MissingBook) -> Bool {
        file.format == candidate.book.format && file.fileSize == candidate.book.fileSize
    }
}
