import XCTest
import GRDB
@testable import EBookReader

/// Guards book identity for the changes the per-file watcher can't see:
/// folders renamed or moved (FSEvents reports only the folder), events
/// FSEvents dropped, and anything changed while the app was closed or
/// before a folder was re-added. Real files in a temp folder, a scratch
/// database migrated with the app's real schema, as in BookRelocationTests.
final class LibraryReconcileTests: XCTestCase {

    private var tempDir: URL!
    private var libraryDir: URL!
    private var dbPool: DatabasePool!
    private var bookRepo: BookRepository!
    private var annotationRepo: AnnotationRepository!
    private var collectionRepo: CollectionRepository!

    private let renamedFolder = FSEventStreamEventFlags(
        kFSEventStreamEventFlagItemIsDir | kFSEventStreamEventFlagItemRenamed
    )

    override func setUpWithError() throws {
        // Canonical path (/private/var/…): it's what FSEvents reports.
        let temp = try XCTUnwrap(realpath(NSTemporaryDirectory(), nil))
        defer { free(temp) }
        tempDir = URL(fileURLWithPath: String(cString: temp), isDirectory: true)
            .appendingPathComponent("EBookReaderReconcileTests-\(UUID().uuidString)", isDirectory: true)
        libraryDir = tempDir.appendingPathComponent("Library", isDirectory: true)
        try FileManager.default.createDirectory(at: libraryDir, withIntermediateDirectories: true)

        dbPool = try DatabasePool(path: tempDir.appendingPathComponent("test.sqlite").path)
        try DatabaseManager.makeMigrator().migrate(dbPool)
        bookRepo = BookRepository(dbPool: dbPool)
        annotationRepo = AnnotationRepository(dbPool: dbPool)
        collectionRepo = CollectionRepository(dbPool: dbPool)
    }

    override func tearDownWithError() throws {
        bookRepo = nil
        annotationRepo = nil
        collectionRepo = nil
        dbPool = nil
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
        libraryDir = nil
    }

    // MARK: - Helpers

    private func url(_ relativePath: String, in root: URL? = nil) -> URL {
        (root ?? libraryDir).appendingPathComponent(relativePath)
    }

    @discardableResult
    private func writeFile(_ relativePath: String, bytes: Int, seed: UInt8 = 1, in root: URL? = nil) throws -> URL {
        let file = url(relativePath, in: root)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: seed, count: bytes).write(to: file)
        return file
    }

    @discardableResult
    private func move(_ from: URL, to destination: URL) throws -> URL {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: from, to: destination)
        return destination
    }

    private func inode(of file: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        return try XCTUnwrap((attributes[.systemFileNumber] as? NSNumber)?.uint64Value)
    }

    @discardableResult
    private func insertBook(at file: URL) async throws -> Book {
        let size = try XCTUnwrap(
            (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value
        )
        let book = Book(
            filePath: file.path,
            fileName: file.lastPathComponent,
            title: file.deletingPathExtension().lastPathComponent,
            format: try XCTUnwrap(FileTypeDetector.detectFormat(from: file)),
            fileSize: size
        )
        try await bookRepo.insertBook(book)
        return book
    }

    /// A book plus the user data a move must not lose: an annotation, a
    /// collection membership, an embedding chunk and a reading position.
    private func insertBookWithUserData(at file: URL) async throws -> Book {
        var book = try await insertBook(at: file)
        book.lastReadPosition = #"{"page":42}"#
        try await bookRepo.updateBook(book)

        try await annotationRepo.insertAnnotation(Annotation(
            bookId: book.id,
            tool: .highlight,
            position: .pdf(pageIndex: 3, bounds: nil),
            selectedText: "Fear is the mind-killer.",
            note: "favourite line"
        ))
        let collection = EBookReader.Collection(name: "Shelf for \(book.id)")
        try await collectionRepo.insertCollection(collection)
        try await collectionRepo.addBook(book.id, toCollection: collection.id)
        try await dbPool.write { db in
            try db.execute(
                sql: "INSERT INTO textChunk (bookId, chunkIndex, text, dateIndexed) VALUES (?, 0, 'chunk', ?)",
                arguments: [book.id, Date()]
            )
        }
        return book
    }

    private func assertUserDataIntact(
        for book: Book,
        nowAt file: URL,
        file sourceFile: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let stored = try await bookRepo.fetchBook(id: book.id)
        let moved = try XCTUnwrap(stored, "book row must survive", file: sourceFile, line: line)
        XCTAssertEqual(moved.filePath, file.path, file: sourceFile, line: line)
        XCTAssertEqual(moved.fileName, file.lastPathComponent, file: sourceFile, line: line)
        XCTAssertEqual(moved.lastReadPosition, book.lastReadPosition, file: sourceFile, line: line)

        let annotations = try await annotationRepo.annotationCount(forBook: book.id)
        XCTAssertEqual(annotations, 1, "annotation lost", file: sourceFile, line: line)

        let collections = try await collectionRepo.fetchAllCollections()
        let collection = try XCTUnwrap(
            collections.first { $0.name == "Shelf for \(book.id)" },
            "collection gone",
            file: sourceFile,
            line: line
        )
        let memberIDs = try await collectionRepo.fetchBookIDs(inCollection: collection.id)
        XCTAssertEqual(memberIDs, [book.id], "collection membership lost", file: sourceFile, line: line)

        let chunks = try await dbPool.read { db in
            try TextChunk.filter(Column("bookId") == book.id).fetchCount(db)
        }
        XCTAssertEqual(chunks, 1, "embedding chunks lost", file: sourceFile, line: line)
    }

    private func path(of bookID: UUID) async throws -> String? {
        try await bookRepo.fetchBook(id: bookID)?.filePath
    }

    private func plan(
        _ events: [FileEvent],
        roots: [URL]? = nil
    ) async -> BookRelocationPlanner.Plan {
        await BookRelocationPlanner.plan(
            for: events,
            repository: bookRepo,
            watchedRoots: (roots ?? [libraryDir]).map(\.path)
        )
    }

    private func reconcile(
        _ folder: URL? = nil,
        roots: [URL]? = nil
    ) async -> BookRelocationPlanner.Plan {
        await BookRelocationPlanner.plan(
            reconcilingFolder: (folder ?? libraryDir).path,
            repository: bookRepo,
            watchedRoots: (roots ?? [libraryDir]).map(\.path)
        )
    }

    private func folderEvent(_ folder: URL, flags: FSEventStreamEventFlags? = nil) -> FileEvent {
        FileEvent(path: folder.path, flags: flags ?? renamedFolder)
    }

    // MARK: - Folder renames and moves (watcher)

    func testFolderRenameKeepsBooksAndUserData() async throws {
        let dune = try writeFile("Sci-Fi/Dune.epub", bytes: 4_096)
        let foundation = try writeFile("Sci-Fi/Asimov/Foundation.pdf", bytes: 5_000, seed: 2)
        let duneBook = try await insertBookWithUserData(at: dune)
        let foundationBook = try await insertBook(at: foundation)

        let oldFolder = url("Sci-Fi")
        let newFolder = try move(oldFolder, to: url("Science Fiction"))
        let result = await plan([folderEvent(oldFolder), folderEvent(newFolder)])

        XCTAssertEqual(Set(result.relocations), [
            .init(bookID: duneBook.id, newPath: url("Science Fiction/Dune.epub").path, fileSize: 4_096),
            .init(bookID: foundationBook.id, newPath: url("Science Fiction/Asimov/Foundation.pdf").path, fileSize: 5_000),
        ])
        XCTAssertEqual(result.imports, [], "books in a renamed folder must not be re-imported")
        XCTAssertEqual(result.missing, [])

        await BookRelocationPlanner.applyRelocations(result, repository: bookRepo)
        try await assertUserDataIntact(for: duneBook, nowAt: url("Science Fiction/Dune.epub"))
        let foundationPath = try await path(of: foundationBook.id)
        XCTAssertEqual(foundationPath, url("Science Fiction/Asimov/Foundation.pdf").path)
        let bookCount = try await bookRepo.bookCount()
        XCTAssertEqual(bookCount, 2)
    }

    func testFolderMoveBetweenWatchedFoldersSplitAcrossBatches() async throws {
        // Each watched folder has its own FSEvents stream, so the two halves
        // of the move arrive as separate batches.
        let archiveDir = tempDir.appendingPathComponent("Archive", isDirectory: true)
        let dune = try writeFile("Herbert/Dune.epub", bytes: 6_000)
        let book = try await insertBookWithUserData(at: dune)

        let oldFolder = url("Herbert")
        let newFolder = try move(oldFolder, to: url("Herbert", in: archiveDir))
        let roots = [libraryDir!, archiveDir]

        let first = await plan([folderEvent(oldFolder)], roots: roots)
        XCTAssertEqual(first.missing, [book.id])
        XCTAssertEqual(first.relocations, [])
        let stillThere = try await bookRepo.fetchBook(id: book.id)
        XCTAssertNotNil(stillThere, "a vanished folder must not delete its books")

        let second = await plan([folderEvent(newFolder)], roots: roots)
        XCTAssertEqual(second.relocations.map(\.bookID), [book.id])
        XCTAssertEqual(second.imports, [])
        await BookRelocationPlanner.applyRelocations(second, repository: bookRepo)
        try await assertUserDataIntact(for: book, nowAt: url("Herbert/Dune.epub", in: archiveDir))
    }

    func testFolderMovedInFromOutsideIsImported() async throws {
        let outside = tempDir.appendingPathComponent("Downloads", isDirectory: true)
        try writeFile("New Books/Hyperion.epub", bytes: 3_000, in: outside)
        try writeFile("New Books/Simmons/Endymion.pdf", bytes: 3_500, in: outside)

        let newFolder = try move(url("New Books", in: outside), to: url("New Books"))
        let result = await plan([folderEvent(newFolder)])

        XCTAssertEqual(Set(result.imports), [
            url("New Books/Hyperion.epub").path,
            url("New Books/Simmons/Endymion.pdf").path,
        ])
        XCTAssertEqual(result.relocations, [])
        XCTAssertEqual(result.missing, [])
    }

    func testFolderTrashedThenPutBackKeepsBooks() async throws {
        let dune = try writeFile("Sci-Fi/Dune.epub", bytes: 4_096)
        let book = try await insertBookWithUserData(at: dune)
        let folder = url("Sci-Fi")

        let trash = try move(folder, to: tempDir.appendingPathComponent("Trash/Sci-Fi"))
        let trashed = await plan([folderEvent(folder)])
        XCTAssertEqual(trashed.missing, [book.id])
        XCTAssertEqual(trashed.relocations, [])
        XCTAssertEqual(trashed.imports, [])
        let annotationsWhileTrashed = try await annotationRepo.annotationCount(forBook: book.id)
        XCTAssertEqual(annotationsWhileTrashed, 1)

        try move(trash, to: folder)
        let restored = await plan([folderEvent(folder)])
        XCTAssertEqual(restored.reappeared, [book.id])
        XCTAssertEqual(restored.relocations, [])
        XCTAssertEqual(restored.imports, [])
        try await assertUserDataIntact(for: book, nowAt: dune)
    }

    func testFolderAndFileRenamedTogetherMatchByInode() async throws {
        // Calibre after a title edit: renames the book file, then its folder.
        let original = try writeFile("Herbert/Dune (1)/Dune - Frank Herbert.epub", bytes: 8_000)
        let book = try await insertBookWithUserData(at: original)

        let renamedFile = try move(original, to: url("Herbert/Dune (1)/Dune Messiah - Frank Herbert.epub"))
        let fileID = try inode(of: renamedFile)
        let oldFolder = url("Herbert/Dune (1)")
        let newFolder = try move(oldFolder, to: url("Herbert/Dune Messiah (1)"))
        let finalURL = url("Herbert/Dune Messiah (1)/Dune Messiah - Frank Herbert.epub")
        // An unrelated file of the same size and format, so size alone can't decide.
        try writeFile("Herbert/Dune Messiah (1)/Notes.epub", bytes: 8_000, seed: 3)

        let result = await plan([
            FileEvent(path: original.path, flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed), fileID: fileID),
            FileEvent(path: renamedFile.path, flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed), fileID: fileID),
            folderEvent(oldFolder),
            folderEvent(newFolder),
        ])

        XCTAssertEqual(result.relocations, [.init(bookID: book.id, newPath: finalURL.path, fileSize: 8_000)])
        XCTAssertEqual(result.imports, [url("Herbert/Dune Messiah (1)/Notes.epub").path])
        await BookRelocationPlanner.applyRelocations(result, repository: bookRepo)
        try await assertUserDataIntact(for: book, nowAt: finalURL)
    }

    func testFolderAndFileRenamedInOneBatchMatchBySizeWhenUnambiguous() async throws {
        let original = try writeFile("Old Title/Old Title.epub", bytes: 9_100)
        let book = try await insertBookWithUserData(at: original)
        let oldFolder = url("Old Title")
        let newFolder = try move(oldFolder, to: url("New Title"))
        let finalURL = try move(url("New Title/Old Title.epub"), to: url("New Title/New Title.epub"))

        let result = await plan([folderEvent(oldFolder), folderEvent(newFolder)])

        XCTAssertEqual(result.relocations.map(\.bookID), [book.id])
        XCTAssertEqual(result.imports, [])
        await BookRelocationPlanner.applyRelocations(result, repository: bookRepo)
        try await assertUserDataIntact(for: book, nowAt: finalURL)
    }

    func testCaseOnlyFolderRenameKeepsSameBooks() async throws {
        let dune = try writeFile("scifi/Dune.epub", bytes: 3_000)
        let book = try await insertBookWithUserData(at: dune)
        let oldFolder = url("scifi")
        let newFolder = url("SciFi")
        XCTAssertEqual(rename(oldFolder.path, newFolder.path), 0)

        let isCaseInsensitive = FileManager.default.fileExists(atPath: oldFolder.path)
        try XCTSkipUnless(isCaseInsensitive, "temp volume is case-sensitive; case-only renames look like normal renames there")

        let result = await plan([folderEvent(oldFolder), folderEvent(newFolder)])

        XCTAssertEqual(result.relocations, [
            .init(bookID: book.id, newPath: url("SciFi/Dune.epub").path, fileSize: 3_000),
        ])
        XCTAssertEqual(result.imports, [], "a case-only folder rename must not duplicate its books")
        await BookRelocationPlanner.applyRelocations(result, repository: bookRepo)
        try await assertUserDataIntact(for: book, nowAt: url("SciFi/Dune.epub"))
    }

    func testFolderEventsFollowScannerRules() async throws {
        let outside = tempDir.appendingPathComponent("Downloads", isDirectory: true)
        try writeFile("Drop/Visible.epub", bytes: 1_000, in: outside)
        try writeFile("Drop/._Visible.epub", bytes: 100, in: outside)
        try writeFile("Drop/.hidden/Secret.epub", bytes: 1_100, in: outside)
        try writeFile("Drop/Reader.app/Contents/Resources/Manual.pdf", bytes: 1_200, in: outside)
        let dropped = try move(url("Drop", in: outside), to: url("Drop"))
        try writeFile(".caltrash/Deleted.epub", bytes: 1_300)

        let scanned = await FolderScanner().scanAll(folderURL: dropped).map(\.url.path)
        let result = await plan([folderEvent(dropped), folderEvent(url(".caltrash"))])

        XCTAssertEqual(result.imports, [url("Drop/Visible.epub").path])
        XCTAssertEqual(result.imports, scanned, "folder events must see exactly what a scan sees")
    }

    func testMetadataOnlyFolderEventDoesNotRescan() async throws {
        try writeFile("Sci-Fi/Dune.epub", bytes: 2_000)
        let xattrChange = FSEventStreamEventFlags(
            kFSEventStreamEventFlagItemIsDir | kFSEventStreamEventFlagItemXattrMod
        )
        let result = await plan([folderEvent(url("Sci-Fi"), flags: xattrChange)])
        XCTAssertEqual(result, BookRelocationPlanner.Plan())
    }

    func testMustScanSubDirsRescansTheSubtree() async throws {
        let renamed = try writeFile("A/Dnue.epub", bytes: 7_000)
        let deleted = try writeFile("A/Deleted.pdf", bytes: 7_100)
        let renamedBook = try await insertBookWithUserData(at: renamed)
        let deletedBook = try await insertBook(at: deleted)
        let unchanged = try await insertBook(at: try writeFile("B/Unchanged.epub", bytes: 7_200))

        let fixedName = try move(renamed, to: url("A/Dune.epub"))
        try FileManager.default.removeItem(at: deleted)
        let added = try writeFile("A/New.epub", bytes: 7_300)

        let dropped = FileEvent(
            path: libraryDir.path,
            flags: FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped)
        )
        let result = await plan([dropped])

        XCTAssertEqual(result.relocations, [.init(bookID: renamedBook.id, newPath: fixedName.path, fileSize: 7_000)])
        XCTAssertEqual(result.imports, [added.path])
        XCTAssertEqual(result.missing, [deletedBook.id])
        XCTAssertTrue(result.reappeared.contains(unchanged.id))
        let stillThere = try await bookRepo.fetchBook(id: deletedBook.id)
        XCTAssertNotNil(stillThere, "a rescan must not delete rows")
    }

    /// End to end with a real FSEvents stream: renaming a folder reaches
    /// the planner as folder-level events, and the books inside keep their
    /// rows. This is the Finder "rename a subfolder" case.
    func testFileWatcherFolderRenameKeepsBooks() async throws {
        let dune = try writeFile("Sci-Fi/Dune.epub", bytes: 4_096)
        let foundation = try writeFile("Sci-Fi/Asimov/Foundation.pdf", bytes: 5_000, seed: 2)
        let duneBook = try await insertBookWithUserData(at: dune)
        let foundationBook = try await insertBook(at: foundation)
        let newFolder = url("Science Fiction")

        let collector = EventCollector()
        let sawNewFolder = expectation(description: "FSEvents reports the renamed folder")
        sawNewFolder.assertForOverFulfill = false
        let watcher = FileWatcher()
        watcher.setChangeHandler { events in
            collector.append(events)
            if events.contains(where: { $0.path == newFolder.path }) {
                sawNewFolder.fulfill()
            }
        }
        watcher.startWatching(path: libraryDir.path)
        defer { watcher.stopAll() }
        try await Task.sleep(for: .milliseconds(300))

        try FileManager.default.moveItem(at: url("Sci-Fi"), to: newFolder)
        await fulfillment(of: [sawNewFolder], timeout: 20)

        let result = await plan(collector.events)
        XCTAssertEqual(Set(result.relocations.map(\.bookID)), [duneBook.id, foundationBook.id])
        XCTAssertEqual(result.imports, [])
        await BookRelocationPlanner.applyRelocations(result, repository: bookRepo)
        try await assertUserDataIntact(for: duneBook, nowAt: url("Science Fiction/Dune.epub"))
        let foundationPath = try await path(of: foundationBook.id)
        XCTAssertEqual(foundationPath, url("Science Fiction/Asimov/Foundation.pdf").path)
    }

    // MARK: - Launch reconcile (changes made while the app was closed)

    func testReconcileWithNoChangesIsEmpty() async throws {
        try await insertBookWithUserData(at: try writeFile("Dune.epub", bytes: 4_000))
        try await insertBook(at: try writeFile("Sub/Foundation.pdf", bytes: 4_100))

        let result = await reconcile()
        XCTAssertEqual(result, BookRelocationPlanner.Plan())
    }

    func testReconcileFindsFileRenamedWhileClosed() async throws {
        let original = try writeFile("Herbert/Dnue.epub", bytes: 4_200)
        let book = try await insertBookWithUserData(at: original)
        let renamed = try move(original, to: url("Herbert/Dune.epub"))

        let result = await reconcile()

        XCTAssertEqual(result.relocations, [.init(bookID: book.id, newPath: renamed.path, fileSize: 4_200)])
        XCTAssertEqual(result.imports, [])
        XCTAssertEqual(result.missing, [])
        await BookRelocationPlanner.applyRelocations(result, repository: bookRepo)
        try await assertUserDataIntact(for: book, nowAt: renamed)
    }

    func testReconcileFindsFileMovedToAnotherSubfolderWhileClosed() async throws {
        let original = try writeFile("Unsorted/Dune.epub", bytes: 4_300)
        let book = try await insertBookWithUserData(at: original)
        let moved = try move(original, to: url("Sci-Fi/Herbert/Dune.epub"))

        let result = await reconcile()

        XCTAssertEqual(result.relocations.map(\.bookID), [book.id])
        XCTAssertEqual(result.imports, [])
        await BookRelocationPlanner.applyRelocations(result, repository: bookRepo)
        try await assertUserDataIntact(for: book, nowAt: moved)
    }

    func testReconcileFindsFolderRenamedWhileClosed() async throws {
        let dune = try writeFile("Sci-Fi/Dune.epub", bytes: 4_400)
        let foundation = try writeFile("Sci-Fi/Foundation.pdf", bytes: 4_500)
        let duneBook = try await insertBookWithUserData(at: dune)
        let foundationBook = try await insertBook(at: foundation)
        try move(url("Sci-Fi"), to: url("Science Fiction"))

        let result = await reconcile()

        XCTAssertEqual(Set(result.relocations.map(\.bookID)), [duneBook.id, foundationBook.id])
        XCTAssertEqual(result.imports, [])
        XCTAssertEqual(result.missing, [])
        await BookRelocationPlanner.applyRelocations(result, repository: bookRepo)
        try await assertUserDataIntact(for: duneBook, nowAt: url("Science Fiction/Dune.epub"))
    }

    func testReconcileImportsNewFilesAndKeepsMissingRows() async throws {
        let gone = try writeFile("Dune.epub", bytes: 4_600)
        let goneBook = try await insertBookWithUserData(at: gone)
        try FileManager.default.removeItem(at: gone)
        let added = try writeFile("Hyperion.epub", bytes: 4_700, seed: 2)

        let result = await reconcile()

        XCTAssertEqual(result.imports, [added.path])
        XCTAssertEqual(result.relocations, [])
        XCTAssertEqual(result.missing, [goneBook.id])
        let annotations = try await annotationRepo.annotationCount(forBook: goneBook.id)
        XCTAssertEqual(annotations, 1, "a missing book keeps its annotations")
    }

    func testReconcileDoesNotGuessFileRenamedAndMovedWithoutEvidence() async throws {
        // Renamed and moved to another folder while closed: no inode, no
        // shared name or folder — only the size agrees, which isn't enough
        // to adopt a book's annotations. Import it; keep the missing row.
        let original = try writeFile("Unsorted/dune.epub", bytes: 4_800)
        let book = try await insertBookWithUserData(at: original)
        let moved = try move(original, to: url("Sci-Fi/Dune - Frank Herbert.epub"))

        let result = await reconcile()

        XCTAssertEqual(result.relocations, [])
        XCTAssertEqual(result.imports, [moved.path])
        XCTAssertEqual(result.missing, [book.id])
    }

    func testReconcileFindsBookMovedFromAnotherWatchedFolder() async throws {
        let archiveDir = tempDir.appendingPathComponent("Archive", isDirectory: true)
        let original = try writeFile("Herbert/Dune.epub", bytes: 4_900, in: archiveDir)
        let book = try await insertBookWithUserData(at: original)
        let moved = try move(original, to: url("Dune.epub"))
        let roots = [libraryDir!, archiveDir]

        let archive = await reconcile(archiveDir, roots: roots)
        XCTAssertEqual(archive.missing, [book.id])
        XCTAssertEqual(archive.relocations, [])

        let library = await reconcile(libraryDir, roots: roots)
        XCTAssertEqual(library.relocations.map(\.bookID), [book.id])
        XCTAssertEqual(library.imports, [])
        await BookRelocationPlanner.applyRelocations(library, repository: bookRepo)
        try await assertUserDataIntact(for: book, nowAt: moved)
    }

    func testReconcileLeavesBooksOnAnUnreachableFolderAlone() async throws {
        // A watched folder on an ejected drive: its books aren't "moved"
        // just because a copy shows up in another folder.
        let ejected = tempDir.appendingPathComponent("Volumes/Drive/Books", isDirectory: true)
        let offline = Book(
            filePath: url("Dune.epub", in: ejected).path,
            fileName: "Dune.epub",
            format: .epub,
            fileSize: 5_000
        )
        try await bookRepo.insertBook(offline)
        let copy = try writeFile("Dune.epub", bytes: 5_000)

        let result = await reconcile(libraryDir, roots: [libraryDir, ejected])

        XCTAssertEqual(result.relocations, [])
        XCTAssertEqual(result.imports, [copy.path])
        let offlinePath = try await path(of: offline.id)
        XCTAssertEqual(offlinePath, offline.filePath)
    }

    // MARK: - Re-adding a watched folder (scanFolder)

    func testRescanningWatchedFolderMatchesRenamedFilesInsteadOfImporting() async throws {
        // scanFolder runs this same reconcile; before, it imported the new
        // name as a second book and left the original row missing.
        let original = try writeFile("Dune.epub", bytes: 5_100)
        let book = try await insertBookWithUserData(at: original)
        let renamed = try move(original, to: url("Dune (Herbert).epub"))
        let added = try writeFile("Hyperion.epub", bytes: 5_200, seed: 2)

        let result = await reconcile()

        XCTAssertEqual(result.relocations, [.init(bookID: book.id, newPath: renamed.path, fileSize: 5_100)])
        XCTAssertEqual(result.imports, [added.path])
        await BookRelocationPlanner.applyRelocations(result, repository: bookRepo)
        try await assertUserDataIntact(for: book, nowAt: renamed)
    }

    // MARK: - Folder queries

    func testFolderPrefixQueryIsExact() async throws {
        let root = "/x/Li_b"
        let paths = [
            "\(root)/a.epub",
            "\(root)/sub/b.pdf",
            "/x/Li_b-Archive/c.epub",   // sibling sharing the prefix
            "/x/LiXb/d.epub",           // `_` must not act as a wildcard
            "/x/li_b/e.epub",           // case matters
            "/x/Li_b",                  // the folder itself isn't a book in it
        ]
        for path in paths {
            try await bookRepo.insertBook(Book(filePath: path, fileName: "f", format: .epub, fileSize: 1))
        }

        let underRoot = try await bookRepo.fetchBookIDsByPath(under: root)
        XCTAssertEqual(Set(underRoot.keys), ["\(root)/a.epub", "\(root)/sub/b.pdf"])
        let withSlash = try await bookRepo.fetchBookIDsByPath(under: root + "/")
        XCTAssertEqual(Set(withSlash.keys), Set(underRoot.keys))

        let existing = try await bookRepo.existingBookPaths(among: ["\(root)/a.epub", "\(root)/nope.epub"])
        XCTAssertEqual(existing, ["\(root)/a.epub"])
    }

    func testFolderQueriesDoNotMatchLookalikeFolders() async throws {
        // `_` was a LIKE wildcard and LIKE ignores ASCII case: removing
        // /x/E_Books used to delete these neighbours (and their annotations).
        let folder = "/x/E_Books"
        var ids: [String: UUID] = [:]
        for path in ["\(folder)/a.epub", "/x/EXBooks/b.epub", "/x/e_books/c.epub", "/x/E_Books-Archive/d.epub"] {
            let book = Book(filePath: path, fileName: "f.epub", format: .epub, fileSize: 1)
            try await bookRepo.insertBook(book)
            try await annotationRepo.insertAnnotation(Annotation(
                bookId: book.id,
                tool: .highlight,
                position: .pdf(pageIndex: 0, bounds: nil)
            ))
            ids[path] = book.id
        }

        let count = try await bookRepo.countBooks(inFolder: folder)
        XCTAssertEqual(count, 1)
        let fetched = try await bookRepo.fetchBooks(inFolder: folder).map(\.filePath)
        XCTAssertEqual(fetched, ["\(folder)/a.epub"])
        let annotations = try await annotationRepo.annotationCount(inFolder: folder)
        XCTAssertEqual(annotations, 1)

        try await bookRepo.deleteBooksInFolder(folder)
        let remaining = Set(try await bookRepo.fetchAllBooks().map(\.filePath))
        XCTAssertEqual(remaining, ["/x/EXBooks/b.epub", "/x/e_books/c.epub", "/x/E_Books-Archive/d.epub"])
        for path in remaining {
            let kept = try await annotationRepo.annotationCount(forBook: try XCTUnwrap(ids[path]))
            XCTAssertEqual(kept, 1, "\(path) lost its annotation")
        }
    }

    // MARK: - Deleted books stay deleted

    func testDeletedBookIsNotImportedAgain() async throws {
        let dune = try writeFile("Sci-Fi/Dune.epub", bytes: 5_300)
        let book = try await insertBookWithUserData(at: dune)
        try await bookRepo.deleteBookExcludingFile(book)

        let atLaunch = await reconcile()
        XCTAssertEqual(atLaunch.imports, [], "Delete from Library must survive the launch reconcile")

        let onFolderEvent = await plan([folderEvent(url("Sci-Fi"), flags: FSEventStreamEventFlags(
            kFSEventStreamEventFlagItemIsDir | kFSEventStreamEventFlagItemCreated
        ))])
        XCTAssertEqual(onFolderEvent.imports, [])

        let onDroppedEvents = await plan([FileEvent(
            path: libraryDir.path,
            flags: FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs)
        )])
        XCTAssertEqual(onDroppedEvents.imports, [])

        let onFileEvent = await plan([FileEvent(
            path: dune.path,
            flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile | kFSEventStreamEventFlagItemModified)
        )])
        XCTAssertEqual(onFileEvent.imports, [])
    }

    func testMissingBookIsRelocatedOntoADeletedBooksPath() async throws {
        // Delete Sci-Fi/Dune.epub from the library, then move the annotated
        // Inbox/Dune.epub over it. The exclusion must not stop the relocation.
        let deletedFile = try writeFile("Sci-Fi/Dune.epub", bytes: 7_000)
        try await bookRepo.deleteBookExcludingFile(try await insertBook(at: deletedFile))
        let inbox = try writeFile("Inbox/Dune.epub", bytes: 7_100, seed: 2)
        let book = try await insertBookWithUserData(at: inbox)

        XCTAssertEqual(rename(inbox.path, deletedFile.path), 0)
        let fileID = try inode(of: deletedFile)
        let renamed = FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile | kFSEventStreamEventFlagItemRenamed)
        let result = await plan([
            FileEvent(path: inbox.path, flags: renamed, fileID: fileID),
            FileEvent(path: deletedFile.path, flags: renamed, fileID: fileID),
        ])

        XCTAssertEqual(result.relocations, [.init(bookID: book.id, newPath: deletedFile.path, fileSize: 7_100)])
        XCTAssertEqual(result.imports, [])
        XCTAssertEqual(result.forgottenExclusions, [deletedFile.path])
        await BookRelocationPlanner.applyRelocations(result, repository: bookRepo)
        try await assertUserDataIntact(for: book, nowAt: deletedFile)
        let exclusions = try await bookRepo.exclusionSizes(forPaths: [deletedFile.path])
        XCTAssertEqual(exclusions, [:], "the exclusion is dropped once a book lives there")
    }

    func testMissingBookIsRelocatedOntoADeletedBooksPathAtLaunch() async throws {
        // Same, while the app was closed, and the moved file is byte-identical
        // to the deleted one: matching still comes first.
        let deletedFile = try writeFile("Sci-Fi/Dune.epub", bytes: 7_200)
        try await bookRepo.deleteBookExcludingFile(try await insertBook(at: deletedFile))
        let inbox = try writeFile("Inbox/Dune.epub", bytes: 7_200)
        let book = try await insertBookWithUserData(at: inbox)
        XCTAssertEqual(rename(inbox.path, deletedFile.path), 0)

        let result = await reconcile()

        XCTAssertEqual(result.relocations.map(\.bookID), [book.id])
        XCTAssertEqual(result.imports, [])
        XCTAssertEqual(result.forgottenExclusions, [deletedFile.path])
        await BookRelocationPlanner.applyRelocations(result, repository: bookRepo)
        try await assertUserDataIntact(for: book, nowAt: deletedFile)
    }

    func testDeletedMissingDuplicateDoesNotBlockRelocation() async throws {
        // Trash a duplicate, delete its (missing) entry, then move the
        // annotated original while the app is closed.
        let original = try writeFile("A/Dune.epub", bytes: 7_300)
        let duplicate = try writeFile("B/Dune.epub", bytes: 7_300)
        let book = try await insertBookWithUserData(at: original)
        let duplicateBook = try await insertBook(at: duplicate)
        try FileManager.default.removeItem(at: duplicate)
        try await bookRepo.deleteBookExcludingFile(duplicateBook)
        let recorded = try await bookRepo.exclusionSizes(forPaths: [duplicate.path])
        XCTAssertEqual(recorded, [:], "deleting a book whose file is gone records nothing")

        let moved = try move(original, to: url("C/Dune.epub"))
        let result = await reconcile()

        XCTAssertEqual(result.relocations.map(\.bookID), [book.id])
        XCTAssertEqual(result.imports, [], "no duplicate import")
        await BookRelocationPlanner.applyRelocations(result, repository: bookRepo)
        try await assertUserDataIntact(for: book, nowAt: moved)
    }

    func testExclusionIsDroppedWhenItsFileIsGoneSoARedownloadImports() async throws {
        let dune = try writeFile("Dune.epub", bytes: 7_400)
        try await bookRepo.deleteBookExcludingFile(try await insertBook(at: dune))
        try FileManager.default.removeItem(at: dune)

        let walk = await reconcile()
        XCTAssertEqual(walk.forgottenExclusions, [dune.path])
        await BookRelocationPlanner.applyRelocations(walk, repository: bookRepo)
        let left = try await bookRepo.exclusionSizes(forPaths: [dune.path])
        XCTAssertEqual(left, [:])

        // The same book downloaded again later is a new book.
        try writeFile("Dune.epub", bytes: 7_400)
        let redownload = await reconcile()
        XCTAssertEqual(redownload.imports, [dune.path])
    }

    func testRemovedEventDropsTheExclusion() async throws {
        let dune = try writeFile("Sci-Fi/Dune.epub", bytes: 7_500)
        try await bookRepo.deleteBookExcludingFile(try await insertBook(at: dune))
        try FileManager.default.removeItem(at: dune)

        let fileRemoved = await plan([FileEvent(
            path: dune.path,
            flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile | kFSEventStreamEventFlagItemRemoved)
        )])
        XCTAssertEqual(fileRemoved.forgottenExclusions, [dune.path])

        // A folder that vanishes takes its exclusions with it too.
        let other = try writeFile("Old/Foundation.epub", bytes: 7_600)
        try await bookRepo.deleteBookExcludingFile(try await insertBook(at: other))
        try move(url("Old"), to: tempDir.appendingPathComponent("Trash/Old"))
        let folderRemoved = await plan([folderEvent(url("Old"))])
        XCTAssertEqual(folderRemoved.forgottenExclusions, [other.path])
    }

    func testExclusionsSurviveAnUnreachableWatchedFolder() async throws {
        // An ejected drive: everything looks gone, but nothing was deleted.
        let ejected = tempDir.appendingPathComponent("Volumes/Drive/Books", isDirectory: true)
        let dune = try writeFile("Dune.epub", bytes: 7_700, in: ejected)
        try await bookRepo.deleteBookExcludingFile(try await insertBook(at: dune))
        try FileManager.default.removeItem(at: tempDir.appendingPathComponent("Volumes/Drive"))

        let result = await plan(
            [FileEvent(path: ejected.path, flags: FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs))],
            roots: [ejected]
        )
        XCTAssertEqual(result.forgottenExclusions, [])
    }

    func testADifferentFileAtADeletedPathIsImported() async throws {
        let dune = try writeFile("Dune.epub", bytes: 7_800)
        try await bookRepo.deleteBookExcludingFile(try await insertBook(at: dune))
        try writeFile("Dune.epub", bytes: 7_900, seed: 4)

        let result = await reconcile()

        XCTAssertEqual(result.imports, [dune.path], "an exclusion holds back only the same path with the same size")
        XCTAssertEqual(result.forgottenExclusions, [dune.path])
    }

    func testAddingTheFolderAgainBringsDeletedBooksBack() async throws {
        let dune = try writeFile("Dune.epub", bytes: 5_700)
        try await bookRepo.insertWatchedFolder(WatchedFolder(path: libraryDir.path, bookmarkData: Data()))
        try await bookRepo.deleteBookExcludingFile(try await insertBook(at: dune))
        let stillDeleted = await reconcile()
        XCTAssertEqual(stillDeleted.imports, [])

        let registration = try await bookRepo.registerFullImportFolder(path: libraryDir.path, bookmarkData: Data([1]))
        XCTAssertEqual(registration, .alreadyWatched)
        let rescan = await reconcile()
        XCTAssertEqual(rescan.imports, [dune.path])
    }

    func testAddingTheFileAgainBringsItBack() async throws {
        let dune = try writeFile("Dune.epub", bytes: 5_800)
        try await bookRepo.deleteBookExcludingFile(try await insertBook(at: dune))

        try await bookRepo.clearExclusions(forPaths: [dune.path])
        let result = await reconcile()
        XCTAssertEqual(result.imports, [dune.path])
    }

    // MARK: - Upgrading: books deleted before exclusions existed

    func testUpgradeFlagsExistingFullImportFolders() throws {
        let path = tempDir.appendingPathComponent("upgrade.sqlite").path
        let pool = try DatabasePool(path: path)
        let migrator = DatabaseManager.makeMigrator()
        try migrator.migrate(pool, upTo: "v8_pooledEmbeddings")
        try pool.write { db in
            try db.execute(
                sql: "INSERT INTO watchedFolder (id, path, bookmarkData, dateAdded, isFullImport) VALUES (?, ?, ?, ?, ?)",
                arguments: [UUID(), "/full", Data(), Date(), true]
            )
            try db.execute(
                sql: "INSERT INTO watchedFolder (id, path, bookmarkData, dateAdded, isFullImport) VALUES (?, ?, ?, ?, ?)",
                arguments: [UUID(), "/partial", Data(), Date(), false]
            )
        }
        try migrator.migrate(pool)

        let flags = try pool.read { db in
            try WatchedFolder.fetchAll(db).reduce(into: [String: Bool]()) { $0[$1.path] = $1.needsExclusionSeed }
        }
        XCTAssertEqual(flags, ["/full": true, "/partial": false])
        XCTAssertFalse(WatchedFolder(path: "/new", bookmarkData: Data()).needsExclusionSeed, "folders added later need no seed")
    }

    func testFirstReconcileAfterUpgradeKeepsEarlierDeletions() async throws {
        // On main a deleted book's file stayed on disk with no row and no
        // record; the first launch of this version must not import it.
        let deletedOnMain = try writeFile("Dune.epub", bytes: 8_100)
        let renamedWhileClosed = try writeFile("Dnue.epub", bytes: 8_200)
        let book = try await insertBookWithUserData(at: renamedWhileClosed)
        let fixed = try move(renamedWhileClosed, to: url("Dune Messiah.epub"))
        let folder = WatchedFolder(path: libraryDir.path, bookmarkData: Data(), needsExclusionSeed: true)
        try await bookRepo.insertWatchedFolder(folder)

        // What AppState does for a flagged folder: relocate, then seed instead of importing.
        let first = await reconcile()
        XCTAssertEqual(first.relocations.map(\.bookID), [book.id])
        XCTAssertEqual(first.imports, [deletedOnMain.path])
        await BookRelocationPlanner.applyRelocations(first, repository: bookRepo)
        try await bookRepo.seedExclusions(forFolder: folder.id, paths: first.imports)

        try await assertUserDataIntact(for: book, nowAt: fixed)
        let seeded = try await bookRepo.fetchAllWatchedFolders()
        XCTAssertEqual(seeded.map(\.needsExclusionSeed), [false], "seeding happens once")
        let next = await reconcile()
        XCTAssertEqual(next.imports, [], "a book deleted before the upgrade stays deleted")

        // Re-adding the folder still brings it back, as on main.
        _ = try await bookRepo.registerFullImportFolder(path: libraryDir.path, bookmarkData: Data())
        let readded = await reconcile()
        XCTAssertEqual(readded.imports, [deletedOnMain.path])
    }

    // MARK: - Removing folders

    func testRemovingAFolderForgetsOnlyItsExclusions() async throws {
        let archiveDir = tempDir.appendingPathComponent("Archive", isDirectory: true)
        let inside = try writeFile("Dune.epub", bytes: 5_900)
        let outside = try writeFile("Dune.epub", bytes: 5_900, in: archiveDir)
        try await bookRepo.deleteBookExcludingFile(try await insertBook(at: inside))
        try await bookRepo.deleteBookExcludingFile(try await insertBook(at: outside))

        try await bookRepo.deleteBooksInFolder(libraryDir.path)

        let excluded = try await bookRepo.exclusionSizes(forPaths: [inside.path, outside.path])
        XCTAssertEqual(Set(excluded.keys), [outside.path])
    }

    func testRemovingAnOuterFolderSparesANestedWatchedFolder() async throws {
        let nestedDir = url("Nested")
        try await bookRepo.insertWatchedFolder(WatchedFolder(path: libraryDir.path, bookmarkData: Data()))
        try await bookRepo.insertWatchedFolder(WatchedFolder(path: nestedDir.path, bookmarkData: Data()))
        let outerBook = try await insertBookWithUserData(at: try writeFile("Outer.epub", bytes: 8_300))
        let nestedBook = try await insertBookWithUserData(at: try writeFile("Nested/Inner.epub", bytes: 8_400))
        let outerDeleted = try writeFile("Gone.epub", bytes: 8_500)
        let nestedDeleted = try writeFile("Nested/Deleted.epub", bytes: 8_600)
        try await bookRepo.deleteBookExcludingFile(try await insertBook(at: outerDeleted))
        try await bookRepo.deleteBookExcludingFile(try await insertBook(at: nestedDeleted))

        let count = try await bookRepo.countBooks(inFolder: libraryDir.path)
        XCTAssertEqual(count, 1, "the confirmation counts only what will go")
        let annotations = try await annotationRepo.annotationCount(inFolder: libraryDir.path)
        XCTAssertEqual(annotations, 1)

        try await bookRepo.deleteBooksInFolder(libraryDir.path)

        let outerStored = try await bookRepo.fetchBook(id: outerBook.id)
        XCTAssertNil(outerStored)
        let nestedStored = try await bookRepo.fetchBook(id: nestedBook.id)
        XCTAssertNotNil(nestedStored, "a still-watched nested folder keeps its books")
        let nestedAnnotations = try await annotationRepo.annotationCount(forBook: nestedBook.id)
        XCTAssertEqual(nestedAnnotations, 1)
        let excluded = try await bookRepo.exclusionSizes(forPaths: [outerDeleted.path, nestedDeleted.path])
        XCTAssertEqual(Set(excluded.keys), [nestedDeleted.path], "and its exclusions")
    }

    func testRemovingAFolderInsideAWatchedFolderKeepsItsBooksDeleted() async throws {
        // Add Books from a subfolder leaves a partial-import entry for it;
        // removing that entry must not hand its books to the outer folder's
        // reconcile to import again.
        try await bookRepo.insertWatchedFolder(WatchedFolder(path: libraryDir.path, bookmarkData: Data()))
        try await bookRepo.insertWatchedFolder(WatchedFolder(path: url("Sci-Fi").path, bookmarkData: Data(), isFullImport: false))
        let dune = try writeFile("Sci-Fi/Dune.epub", bytes: 6_000)
        try await insertBook(at: dune)
        let goneFile = try writeFile("Sci-Fi/Gone.epub", bytes: 6_050)
        try await insertBook(at: goneFile)
        try FileManager.default.removeItem(at: goneFile)

        try await bookRepo.deleteBooksInFolder(url("Sci-Fi").path)

        let bookCount = try await bookRepo.bookCount()
        XCTAssertEqual(bookCount, 0)
        let excluded = try await bookRepo.exclusionSizes(forPaths: [dune.path, goneFile.path])
        XCTAssertEqual(excluded, [dune.path: 6_000], "only files still on disk are recorded")
        let result = await reconcile()
        XCTAssertEqual(result.imports, [])
    }

    // MARK: - Add Folder after Add Books

    func testAddFolderUpgradesAFolderWhoseBooksWereAddedOneByOne() async throws {
        // Add Books leaves a partial-import entry for the file's folder.
        let picked = try writeFile("Dune.epub", bytes: 6_100)
        let other = try writeFile("Sub/Foundation.epub", bytes: 6_200)
        let partial = WatchedFolder(path: libraryDir.path, bookmarkData: Data(), isFullImport: false)
        try await bookRepo.insertWatchedFolder(partial)
        let pickedBook = try await insertBook(at: picked)

        let registration = try await bookRepo.registerFullImportFolder(path: libraryDir.path, bookmarkData: Data([7]))

        XCTAssertEqual(registration, .upgradedFromPartialImport)
        let folders = try await bookRepo.fetchAllWatchedFolders()
        XCTAssertEqual(folders.count, 1, "upgraded in place, not duplicated")
        XCTAssertEqual(folders.first?.id, partial.id)
        XCTAssertEqual(folders.first?.isFullImport, true)
        XCTAssertEqual(folders.first?.bookmarkData, Data([7]))

        // The scan that follows treats it as a full-import root, so the rest of
        // the folder is imported and the book added earlier is kept as is.
        let fullImportRoots = folders.filter(\.isFullImport).map(\.path)
        let scan = await BookRelocationPlanner.plan(
            reconcilingFolder: libraryDir.path,
            repository: bookRepo,
            watchedRoots: fullImportRoots
        )
        XCTAssertEqual(scan.imports, [other.path])
        XCTAssertEqual(scan.relocations, [])
        let pickedPath = try await path(of: pickedBook.id)
        XCTAssertEqual(pickedPath, picked.path)
    }

    func testAddFolderRegistersANewFolderOnce() async throws {
        let first = try await bookRepo.registerFullImportFolder(path: libraryDir.path, bookmarkData: Data([1]))
        let second = try await bookRepo.registerFullImportFolder(path: libraryDir.path, bookmarkData: Data([2]))
        XCTAssertEqual(first, .added)
        XCTAssertEqual(second, .alreadyWatched)
        let folders = try await bookRepo.fetchAllWatchedFolders()
        XCTAssertEqual(folders.map(\.isFullImport), [true])
    }

    // MARK: - Applying relocations

    func testFolderRenameIsAppliedInAFewTransactions() async throws {
        let count = 1_200
        var books: [Book] = []
        for i in 0..<count {
            let file = try writeFile("Big/Book \(i).epub", bytes: 100 + i)
            books.append(Book(filePath: file.path, fileName: file.lastPathComponent, format: .epub, fileSize: Int64(100 + i)))
        }
        try await bookRepo.insertBooks(books)
        let oldFolder = url("Big")
        let newFolder = try move(oldFolder, to: url("Bigger"))
        let result = await plan([folderEvent(oldFolder), folderEvent(newFolder)])
        XCTAssertEqual(result.relocations.count, count)

        let commits = BookCommitCounter()
        dbPool.add(transactionObserver: commits)
        let applied = await BookRelocationPlanner.applyRelocations(result, repository: bookRepo)

        XCTAssertEqual(applied.count, count)
        XCTAssertLessThanOrEqual(commits.count, 3, "one commit per 500 relocations, not one per book")
        let moved = try await bookRepo.fetchBooks(inFolder: newFolder.path).count
        XCTAssertEqual(moved, count)
    }

    func testRelocationsSkipCollisionsAndLandChains() async throws {
        let a = Book(filePath: "/L/a.epub", fileName: "a.epub", format: .epub, fileSize: 1)
        let b = Book(filePath: "/L/b.epub", fileName: "b.epub", format: .epub, fileSize: 2)
        let c = Book(filePath: "/L/c.epub", fileName: "c.epub", format: .epub, fileSize: 3)
        let d = Book(filePath: "/L/d.epub", fileName: "d.epub", format: .epub, fileSize: 4)
        try await bookRepo.insertBooks([a, b, c, d])

        let applied = try await bookRepo.relocateBooks([
            .init(bookID: a.id, newPath: "/L/b.epub", fileSize: 1),   // b's old path, freed below
            .init(bookID: b.id, newPath: "/L/e.epub", fileSize: 2),
            .init(bookID: c.id, newPath: "/L/d.epub", fileSize: 3),   // d stays: collision
        ])

        XCTAssertEqual(Set(applied.map(\.bookID)), [a.id, b.id])
        let paths = try await bookRepo.fetchBooks(byIds: [a.id, b.id, c.id, d.id])
            .reduce(into: [UUID: String]()) { $0[$1.id] = $1.filePath }
        XCTAssertEqual(paths, [a.id: "/L/b.epub", b.id: "/L/e.epub", c.id: "/L/c.epub", d.id: "/L/d.epub"])
    }

    // MARK: - Scale

    func testReconcileOfLargeFolderStaysCheap() async throws {
        let count = 25_000
        var books: [Book] = []
        books.reserveCapacity(count)
        for i in 0..<count {
            let file = url(String(format: "Author %03d/Book %05d.epub", i % 250, i))
            if i < 250 {
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            }
            // Sparse files: sizes stay distinct without writing 25k × KB.
            FileManager.default.createFile(atPath: file.path, contents: nil)
            let handle = try FileHandle(forWritingTo: file)
            try handle.truncate(atOffset: UInt64(10_000 + i))
            try handle.close()
            books.append(Book(filePath: file.path, fileName: file.lastPathComponent, format: .epub, fileSize: Int64(10_000 + i)))
        }
        try await bookRepo.insertBooks(books)

        let unchangedStart = Date()
        let unchanged = await reconcile()
        let unchangedSeconds = Date().timeIntervalSince(unchangedStart)
        XCTAssertEqual(unchanged, BookRelocationPlanner.Plan())

        let renamed = try move(URL(fileURLWithPath: books[123].filePath), to: url("Author 123/Renamed.epub"))
        let changedStart = Date()
        let changed = await reconcile()
        let changedSeconds = Date().timeIntervalSince(changedStart)
        XCTAssertEqual(changed.relocations, [.init(bookID: books[123].id, newPath: renamed.path, fileSize: 10_123)])
        XCTAssertEqual(changed.imports, [])

        print("Reconcile of \(count) books: \(unchangedSeconds)s unchanged, \(changedSeconds)s with one rename")
        XCTAssertLessThan(unchangedSeconds, 10, "launch reconcile must stay cheap at 25k books")
        XCTAssertLessThan(changedSeconds, 10)
    }
}

/// Counts committed transactions that changed the book table.
private final class BookCommitCounter: TransactionObserver, @unchecked Sendable {
    private let lock = NSLock()
    private var commits = 0
    private var changedBooks = false

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return commits
    }

    func observes(eventsOfKind eventKind: DatabaseEventKind) -> Bool {
        eventKind.tableName == "book"
    }

    func databaseDidChange(with event: DatabaseEvent) {
        lock.lock()
        changedBooks = true
        lock.unlock()
    }

    func databaseDidCommit(_ db: Database) {
        lock.lock()
        if changedBooks { commits += 1 }
        changedBooks = false
        lock.unlock()
    }

    func databaseDidRollback(_ db: Database) {
        lock.lock()
        changedBooks = false
        lock.unlock()
    }
}

/// Collects FSEvents batches from the watcher's queue.
private final class EventCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var collected: [FileEvent] = []

    func append(_ events: [FileEvent]) {
        lock.lock()
        collected += events
        lock.unlock()
    }

    var events: [FileEvent] {
        lock.lock()
        defer { lock.unlock() }
        return collected
    }
}
