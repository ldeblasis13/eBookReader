import Foundation

/// Works out what changes on disk mean for the library.
///
/// A book's identity is its row UUID, not its path: annotations, collection
/// memberships, reading position and embeddings all reference `book.id` with
/// ON DELETE CASCADE. So a renamed or moved book file keeps its row (only the
/// path changes), and a file that disappears keeps its row too — the UI shows
/// it as missing until the user deletes it explicitly. Nothing here deletes.
///
/// Two entry points share the same matching: `plan(for:)` reads a batch of
/// FSEvents, and `plan(reconcilingFolder:)` diffs a whole folder against
/// its rows, for changes the watcher never saw (made while the app was
/// closed, or before a folder was re-added).
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

    struct Relocation: Hashable, Sendable {
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
        /// True when this batch had an event for the book's old path, or
        /// for a folder above it that vanished.
        let reportedInBatch: Bool
    }

    // MARK: - Planning

    /// Plans one batch of FSEvents.
    ///
    /// Book-file events are looked at directly. A folder that was created,
    /// removed, renamed or moved is reported only by its own path, so it's
    /// rescanned: book files inside it count as appeared, and rows under a
    /// folder that's gone count as missing. So is any path FSEvents says it
    /// dropped events under (MustScanSubDirs).
    ///
    /// `watchedRoots` are the full-import folder paths. FolderScanner's
    /// hidden-file and package rules apply below them, and a missing book
    /// is only matched while the watched folder it's in is still there.
    static func plan(
        for events: [FileEvent],
        repository: BookRepository,
        watchedRoots: [String] = [],
        fileManager: FileManager = .default
    ) async -> Plan {
        let roots = normalized(watchedRoots)

        // One entry per book-file path, keeping every inode reported for it.
        var orderedPaths: [String] = []
        var fileIDsByPath: [String: Set<UInt64>] = [:]
        var directories: [String] = []
        for event in events {
            switch target(of: event, fileManager: fileManager) {
            case .ignored:
                continue
            case .directory:
                if !isExcluded(event.path, isDirectory: true, roots: roots, fileManager: fileManager) {
                    directories.append(event.path)
                }
            case .bookFile:
                // Hidden files (e.g. AppleDouble "._book.pdf") are skipped, as FolderScanner does.
                guard !isExcluded(event.path, isDirectory: false, roots: roots, fileManager: fileManager) else { continue }
                if fileIDsByPath[event.path] == nil {
                    orderedPaths.append(event.path)
                    fileIDsByPath[event.path] = []
                }
                if let fileID = event.fileID {
                    fileIDsByPath[event.path]?.insert(fileID)
                }
            }
        }

        var findings = Findings()

        for path in orderedPaths {
            let existing = try? await repository.fetchBook(byPath: path)
            if let attributes = try? fileManager.attributesOfItem(atPath: path) {
                if let existing {
                    findings.addPresent(id: existing.id, path: existing.filePath, reappeared: true, mayBeCaseRenamed: true)
                    continue
                }
                guard attributes[.type] as? FileAttributeType == .typeRegular,
                      let format = FileTypeDetector.detectFormat(from: URL(fileURLWithPath: path))
                else { continue }
                let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
                findings.addAppeared(AppearedFile(
                    path: path,
                    fileSize: (attributes[.size] as? NSNumber)?.int64Value ?? 0,
                    format: format,
                    fileID: inode ?? fileIDsByPath[path]?.first
                ))
            } else if let existing {
                findings.addMissing(existing, eventFileIDs: fileIDsByPath[path] ?? [], reportedInBatch: true)
            }
        }

        let vanished = directories.filter { !isDirectory($0, fileManager: fileManager) }
        for directory in outermost(directories) {
            await collect(
                subtree: directory,
                into: &findings,
                fromEvents: true,
                vanishedDirectories: vanished,
                repository: repository,
                fileManager: fileManager
            )
        }

        return await finish(findings, repository: repository, roots: roots, fileManager: fileManager)
    }

    /// Diffs everything under a watched folder against the library's rows
    /// for it: files no row points to are matched to missing books (moved
    /// or renamed while nobody was watching) or imported; rows whose file
    /// is gone stay, as missing. Cost is one indexed range query and one
    /// directory walk, plus lookups only for whatever differs.
    static func plan(
        reconcilingFolder folderPath: String,
        repository: BookRepository,
        watchedRoots: [String] = [],
        fileManager: FileManager = .default
    ) async -> Plan {
        let roots = normalized(watchedRoots + [folderPath])
        var findings = Findings()
        await collect(
            subtree: folderPath,
            into: &findings,
            fromEvents: false,
            vanishedDirectories: [],
            repository: repository,
            fileManager: fileManager
        )
        return await finish(findings, repository: repository, roots: roots, fileManager: fileManager)
    }

    // MARK: - Collecting

    /// What a planning pass has found, before matching.
    private struct Findings {
        private(set) var appeared: [AppearedFile] = []
        private var appearedPaths: Set<String> = []
        private(set) var missing: [UUID: MissingBook] = [:]
        private(set) var missingOrder: [UUID] = []
        /// Rows whose file still resolves at the recorded path. On a
        /// case-insensitive volume that includes case-only renames, so
        /// these are checked against appeared files by inode.
        private(set) var caseRenameCandidates: [(id: UUID, path: String)] = []
        private var caseRenameCandidateIDs: Set<UUID> = []
        private(set) var presentIDs: Set<UUID> = []
        private(set) var reappeared: [UUID] = []
        private var reappearedIDs: Set<UUID> = []

        mutating func addAppeared(_ file: AppearedFile) {
            guard appearedPaths.insert(file.path).inserted else { return }
            appeared.append(file)
        }

        mutating func addMissing(_ book: Book, eventFileIDs: Set<UInt64>, reportedInBatch: Bool) {
            if let known = missing[book.id] {
                missing[book.id] = MissingBook(
                    book: book,
                    eventFileIDs: known.eventFileIDs.union(eventFileIDs),
                    reportedInBatch: known.reportedInBatch || reportedInBatch
                )
            } else {
                missing[book.id] = MissingBook(book: book, eventFileIDs: eventFileIDs, reportedInBatch: reportedInBatch)
                missingOrder.append(book.id)
            }
        }

        mutating func addPresent(id: UUID, path: String, reappeared isReappeared: Bool, mayBeCaseRenamed: Bool) {
            presentIDs.insert(id)
            if mayBeCaseRenamed, caseRenameCandidateIDs.insert(id).inserted {
                caseRenameCandidates.append((id, path))
            }
            if isReappeared, reappearedIDs.insert(id).inserted {
                reappeared.append(id)
            }
        }
    }

    /// Diffs one directory's book files against the rows recorded under it.
    /// If the directory is gone, every row under it is checked as missing.
    private static func collect(
        subtree directory: String,
        into findings: inout Findings,
        fromEvents: Bool,
        vanishedDirectories: [String],
        repository: BookRepository,
        fileManager: FileManager
    ) async {
        let rows = (try? await repository.fetchBookIDsByPath(under: directory)) ?? [:]

        var onDisk = Set<String>()
        if isDirectory(directory, fileManager: fileManager) {
            let url = URL(fileURLWithPath: directory, isDirectory: true)
            FolderScanner.forEachBookFile(in: url, fileManager: fileManager) { info in
                let path = info.url.path
                onDisk.insert(path)
                if let id = rows[path] {
                    // Under an FSEvents path the directory part may be the
                    // old spelling of a case-only folder rename.
                    findings.addPresent(id: id, path: path, reappeared: fromEvents, mayBeCaseRenamed: fromEvents)
                } else {
                    findings.addAppeared(AppearedFile(path: path, fileSize: info.fileSize, format: info.format, fileID: nil))
                }
            }
        }

        // Rows the walk didn't see: gone, or still there under a name the
        // walk skips (hidden, inside a package) or spells differently.
        var goneIDs: [UUID] = []
        for (path, id) in rows where !onDisk.contains(path) {
            if fileManager.fileExists(atPath: path) {
                findings.addPresent(id: id, path: path, reappeared: fromEvents, mayBeCaseRenamed: true)
            } else {
                goneIDs.append(id)
            }
        }
        guard !goneIDs.isEmpty else { return }

        let goneBooks = ((try? await repository.fetchBooks(byIds: goneIDs)) ?? [])
            .sorted { $0.filePath < $1.filePath }
        for book in goneBooks {
            findings.addMissing(
                book,
                eventFileIDs: [],
                reportedInBatch: vanishedDirectories.contains { isPath(book.filePath, inside: $0) }
            )
        }
    }

    /// Matches what was found and turns it into a plan.
    private static func finish(
        _ findings: Findings,
        repository: BookRepository,
        roots: [String],
        fileManager: FileManager
    ) async -> Plan {
        var appeared = findings.appeared
        var missing = findings.missing

        // Books that went missing in an earlier batch, in another watched
        // folder, or while the app was closed can still be matched by size
        // and format. Skip rows whose watched folder is gone too — most
        // likely an unmounted volume, not a moved file.
        if !appeared.isEmpty {
            let sizes = Set(appeared.map(\.fileSize))
            let candidates = (try? await repository.fetchBooks(withFileSizes: sizes)) ?? []
            var reachable: [String: Bool] = [:]
            for book in candidates where missing[book.id] == nil && !findings.presentIDs.contains(book.id) {
                guard !fileManager.fileExists(atPath: book.filePath),
                      isLibraryFolderReachable(for: book.filePath, roots: roots, cache: &reachable, fileManager: fileManager)
                else { continue }
                missing[book.id] = MissingBook(book: book, eventFileIDs: [], reportedInBatch: false)
            }
        }

        // FSEvents gave the old path's inode; files found by walking a
        // folder don't have theirs yet. Only look them up when it can matter.
        if missing.values.contains(where: { !$0.eventFileIDs.isEmpty }) {
            appeared = appeared.map { file in
                guard file.fileID == nil else { return file }
                return AppearedFile(
                    path: file.path,
                    fileSize: file.fileSize,
                    format: file.format,
                    fileID: inode(of: file.path, fileManager: fileManager)
                )
            }
        }

        // A case-only rename ("dune.epub" → "Dune.epub") on a case-insensitive
        // volume: the old path still resolves to the same file, so the book
        // never looks missing. Match it by inode instead.
        var caseRenames: [Relocation] = []
        if !appeared.isEmpty, !findings.caseRenameCandidates.isEmpty {
            let appearedByFoldedPath = Dictionary(grouping: appeared) { $0.path.lowercased() }
            for row in findings.caseRenameCandidates {
                guard let sameButCase = appearedByFoldedPath[row.path.lowercased()],
                      sameButCase.contains(where: { $0.path != row.path }),
                      let inode = inode(of: row.path, fileManager: fileManager),
                      let file = sameButCase.first(where: {
                          $0.path != row.path
                              && $0.path.compare(row.path, options: .caseInsensitive) == .orderedSame
                              && ($0.fileID ?? self.inode(of: $0.path, fileManager: fileManager)) == inode
                      }),
                      !caseRenames.contains(where: { $0.newPath == file.path || $0.bookID == row.id })
                else { continue }
                caseRenames.append(Relocation(bookID: row.id, newPath: file.path, fileSize: file.fileSize))
            }
        }
        let caseRenamedPaths = Set(caseRenames.map(\.newPath))
        let caseRenamedIDs = Set(caseRenames.map(\.bookID))

        var plan = Plan()
        plan.relocations = caseRenames + match(
            appeared: appeared.filter { !caseRenamedPaths.contains($0.path) },
            missing: missing.values.filter { !caseRenamedIDs.contains($0.book.id) }
        )
        let relocatedPaths = Set(plan.relocations.map(\.newPath))
        let relocatedIDs = Set(plan.relocations.map(\.bookID))
        plan.imports = appeared.map(\.path).filter { !relocatedPaths.contains($0) }
        plan.missing = findings.missingOrder.filter { !relocatedIDs.contains($0) }
        plan.reappeared = findings.reappeared.filter { !relocatedIDs.contains($0) }
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

    // MARK: - Events

    private enum EventTarget {
        case bookFile
        case directory
        case ignored
    }

    private static let mustRescanFlags = FSEventStreamEventFlags(
        kFSEventStreamEventFlagMustScanSubDirs
            | kFSEventStreamEventFlagUserDropped
            | kFSEventStreamEventFlagKernelDropped
    )
    private static let structuralFlags = FSEventStreamEventFlags(
        kFSEventStreamEventFlagItemCreated
            | kFSEventStreamEventFlagItemRemoved
            | kFSEventStreamEventFlagItemRenamed
    )

    private static func target(of event: FileEvent, fileManager: FileManager) -> EventTarget {
        let flags = event.flags
        if flags & mustRescanFlags != 0 { return .directory }

        if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) == 0 {
            if FileTypeDetector.isSupportedBookFile(URL(fileURLWithPath: event.path)) { return .bookFile }
            if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile | kFSEventStreamEventFlagItemIsSymlink) != 0 {
                return .ignored
            }
            // No item-type flag: only a directory that's still there can be told apart.
            guard isDirectory(event.path, fileManager: fileManager) else { return .ignored }
        }
        // Metadata-only changes (xattrs, Finder info, permissions) move
        // nothing. No flags at all is FSEvents' "something changed in here".
        return flags == 0 || flags & structuralFlags != 0 ? .directory : .ignored
    }

    /// FolderScanner's rules, for a path FSEvents reported: nothing hidden
    /// and nothing inside a package, judged below the watched folder it's in.
    private static func isExcluded(
        _ path: String,
        isDirectory: Bool,
        roots: [String],
        fileManager: FileManager
    ) -> Bool {
        guard let root = containingRoot(of: path, in: roots) else {
            return (path as NSString).lastPathComponent.hasPrefix(".")
        }
        guard path != root else { return false }
        let components = path.dropFirst(root.count).split(separator: "/")
        if components.contains(where: { $0.hasPrefix(".") }) { return true }

        // Packages (.app, .rtfd, …) are opaque to the scan.
        var ancestor = root
        for component in isDirectory ? components[...] : components.dropLast() {
            ancestor += "/" + component
            let values = try? URL(fileURLWithPath: ancestor).resourceValues(forKeys: [.isPackageKey])
            if values?.isPackage == true { return true }
        }
        return false
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

    private static func normalized(_ roots: [String]) -> [String] {
        Array(Set(roots.map { $0.count > 1 && $0.hasSuffix("/") ? String($0.dropLast()) : $0 }))
    }

    private static func isPath(_ path: String, inside directory: String) -> Bool {
        path.hasPrefix(directory.hasSuffix("/") ? directory : directory + "/")
    }

    /// The innermost watched folder `path` is in (or is).
    private static func containingRoot(of path: String, in roots: [String]) -> String? {
        roots
            .filter { path == $0 || isPath(path, inside: $0) }
            .max { $0.count < $1.count }
    }

    /// Directories to walk, without any that sit inside another one.
    private static func outermost(_ directories: [String]) -> [String] {
        var result: [String] = []
        for directory in Set(directories).sorted(by: { $0.count < $1.count })
        where !result.contains(where: { directory == $0 || isPath(directory, inside: $0) }) {
            result.append(directory)
        }
        return result
    }

    /// A missing book only counts as moved or deleted while the watched
    /// folder it's in (or, outside any, its own folder) is still there.
    private static func isLibraryFolderReachable(
        for path: String,
        roots: [String],
        cache: inout [String: Bool],
        fileManager: FileManager
    ) -> Bool {
        let folder = containingRoot(of: path, in: roots) ?? (path as NSString).deletingLastPathComponent
        if let known = cache[folder] { return known }
        let exists = fileManager.fileExists(atPath: folder)
        cache[folder] = exists
        return exists
    }

    private static func isDirectory(_ path: String, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private static func inode(of path: String, fileManager: FileManager) -> UInt64? {
        (try? fileManager.attributesOfItem(atPath: path))
            .flatMap { ($0[.systemFileNumber] as? NSNumber)?.uint64Value }
    }
}
