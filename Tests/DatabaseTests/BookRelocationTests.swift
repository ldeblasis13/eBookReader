import XCTest
import GRDB
@testable import EBookReader

/// Guards book identity across renames and moves in watched folders.
///
/// Annotations, collection memberships, embeddings and reading position all
/// hang off `book.id` with ON DELETE CASCADE. These tests drive
/// BookRelocationPlanner with real files in a temp folder and synthetic
/// FSEvents, against a scratch database migrated with the app's real schema,
/// and check that a renamed/moved file keeps its book row (same UUID, new
/// path) and that a vanished file never deletes anything.
final class BookRelocationTests: XCTestCase {

    private var tempDir: URL!
    private var libraryDir: URL!
    private var dbPool: DatabasePool!
    private var bookRepo: BookRepository!
    private var annotationRepo: AnnotationRepository!
    private var collectionRepo: CollectionRepository!

    private let renamed = FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed)

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("EBookReaderRelocationTests-\(UUID().uuidString)", isDirectory: true)
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

    @discardableResult
    private func writeFile(_ relativePath: String, bytes: Int, seed: UInt8 = 1) throws -> URL {
        let url = libraryDir.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(repeating: seed, count: bytes).write(to: url)
        return url
    }

    private func move(_ from: URL, to relativePath: String) throws -> URL {
        let to = libraryDir.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: to.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.moveItem(at: from, to: to)
        return to
    }

    private func inode(of url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap((attributes[.systemFileNumber] as? NSNumber)?.uint64Value)
    }

    /// Inserts a book for `url` plus the user data a rename must not lose:
    /// an annotation, a collection membership, an embedding chunk and a
    /// reading position.
    private func insertBookWithUserData(at url: URL) async throws -> Book {
        let size = try XCTUnwrap(
            (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
        )
        let book = Book(
            filePath: url.path,
            fileName: url.lastPathComponent,
            title: "Dune",
            format: try XCTUnwrap(FileTypeDetector.detectFormat(from: url)),
            fileSize: size,
            lastReadPosition: #"{"page":42}"#,
            fullTextIndexed: true,
            embeddingIndexed: true
        )
        try await bookRepo.insertBook(book)

        try await annotationRepo.insertAnnotation(Annotation(
            bookId: book.id,
            tool: .highlight,
            position: .pdf(pageIndex: 3, bounds: nil),
            selectedText: "Fear is the mind-killer.",
            note: "favourite line"
        ))

        let collection = EBookReader.Collection(name: "Sci-Fi")
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
        nowAt url: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let stored = try await bookRepo.fetchBook(id: book.id)
        let moved = try XCTUnwrap(stored, "book row must survive the move", file: file, line: line)
        XCTAssertEqual(moved.filePath, url.path, file: file, line: line)
        XCTAssertEqual(moved.fileName, url.lastPathComponent, file: file, line: line)
        XCTAssertEqual(moved.lastReadPosition, book.lastReadPosition, file: file, line: line)
        XCTAssertTrue(moved.fullTextIndexed && moved.embeddingIndexed, file: file, line: line)

        let bookCount = try await bookRepo.bookCount()
        XCTAssertEqual(bookCount, 1, "no duplicate row for the new path", file: file, line: line)

        let annotations = try await annotationRepo.annotationCount(forBook: book.id)
        XCTAssertEqual(annotations, 1, "annotation lost", file: file, line: line)

        let collections = try await collectionRepo.fetchAllCollections()
        let collection = try XCTUnwrap(collections.first, file: file, line: line)
        let memberIDs = try await collectionRepo.fetchBookIDs(inCollection: collection.id)
        XCTAssertEqual(memberIDs, [book.id], "collection membership lost", file: file, line: line)

        let chunks = try await dbPool.read { db in
            try TextChunk.filter(Column("bookId") == book.id).fetchCount(db)
        }
        XCTAssertEqual(chunks, 1, "embedding chunks lost", file: file, line: line)
    }

    private func plan(_ events: [FileEvent]) async -> BookRelocationPlanner.Plan {
        await BookRelocationPlanner.plan(for: events, repository: bookRepo)
    }

    // MARK: - Renames and moves keep the same book

    func testRenameKeepsSameBookAndUserData() async throws {
        let original = try writeFile("Dune.epub", bytes: 4_096)
        let book = try await insertBookWithUserData(at: original)

        let renamedURL = try move(original, to: "Dune (Herbert).epub")
        let fileID = try inode(of: renamedURL)
        let result = await plan([
            FileEvent(path: original.path, flags: renamed, fileID: fileID),
            FileEvent(path: renamedURL.path, flags: renamed, fileID: fileID),
        ])

        XCTAssertEqual(result.relocations, [
            .init(bookID: book.id, newPath: renamedURL.path, fileSize: 4_096),
        ])
        XCTAssertEqual(result.imports, [], "a renamed book must not be re-imported as a new book")
        XCTAssertEqual(result.missing, [])

        let applied = await BookRelocationPlanner.applyRelocations(result, repository: bookRepo)
        XCTAssertEqual(applied.count, 1)
        try await assertUserDataIntact(for: book, nowAt: renamedURL)
    }

    func testMoveIntoSubfolderWithoutInodeMatchesByNameAndSize() async throws {
        let original = try writeFile("Dune.epub", bytes: 5_000)
        let book = try await insertBookWithUserData(at: original)

        let movedURL = try move(original, to: "Herbert/Dune.epub")
        let result = await plan([
            FileEvent(path: original.path, flags: renamed),
            FileEvent(path: movedURL.path, flags: renamed),
        ])

        XCTAssertEqual(result.relocations.map(\.bookID), [book.id])
        XCTAssertEqual(result.imports, [])
        await BookRelocationPlanner.applyRelocations(result, repository: bookRepo)
        try await assertUserDataIntact(for: book, nowAt: movedURL)
    }

    func testMoveBetweenFoldersSplitAcrossBatchesKeepsSameBook() async throws {
        // A move between two watched folders reaches us as two callbacks from
        // two FSEvents streams, in either order.
        let original = try writeFile("Dune.pdf", bytes: 6_000)
        let book = try await insertBookWithUserData(at: original)
        let movedURL = try move(original, to: "Other Folder/Dune.pdf")

        let first = await plan([FileEvent(path: original.path, flags: renamed)])
        XCTAssertEqual(first.missing, [book.id])
        XCTAssertEqual(first.relocations, [])
        let stillThere = try await bookRepo.fetchBook(id: book.id)
        XCTAssertNotNil(stillThere, "a vanished file must not delete its book")

        let second = await plan([FileEvent(path: movedURL.path, flags: renamed)])
        XCTAssertEqual(second.relocations.map(\.bookID), [book.id])
        XCTAssertEqual(second.imports, [])
        await BookRelocationPlanner.applyRelocations(second, repository: bookRepo)
        try await assertUserDataIntact(for: book, nowAt: movedURL)
    }

    func testRenameWithHalvesInSeparateBatchesMatchesWithinFolder() async throws {
        let original = try writeFile("Dnue.epub", bytes: 7_000)
        let book = try await insertBookWithUserData(at: original)
        let renamedURL = try move(original, to: "Dune.epub")

        _ = await plan([FileEvent(path: original.path, flags: renamed)])
        let result = await plan([FileEvent(path: renamedURL.path, flags: renamed)])

        XCTAssertEqual(result.relocations.map(\.bookID), [book.id])
        await BookRelocationPlanner.applyRelocations(result, repository: bookRepo)
        try await assertUserDataIntact(for: book, nowAt: renamedURL)
    }

    func testCaseOnlyRenameKeepsSameBook() async throws {
        let original = try writeFile("dune.epub", bytes: 3_000)
        let book = try await insertBookWithUserData(at: original)
        let renamedURL = libraryDir.appendingPathComponent("Dune.epub")
        XCTAssertEqual(rename(original.path, renamedURL.path), 0)

        let isCaseInsensitive = FileManager.default.fileExists(atPath: original.path)
        try XCTSkipUnless(isCaseInsensitive, "temp volume is case-sensitive; case-only renames look like normal renames there")

        let fileID = try inode(of: renamedURL)
        let result = await plan([
            FileEvent(path: original.path, flags: renamed, fileID: fileID),
            FileEvent(path: renamedURL.path, flags: renamed, fileID: fileID),
        ])

        XCTAssertEqual(result.relocations.map(\.bookID), [book.id])
        XCTAssertEqual(result.imports, [], "a case-only rename must not create a duplicate book")
        await BookRelocationPlanner.applyRelocations(result, repository: bookRepo)
        try await assertUserDataIntact(for: book, nowAt: renamedURL)
    }

    // MARK: - Disappearing files are never deleted

    func testTrashThenPutBackKeepsBook() async throws {
        let original = try writeFile("Dune.epub", bytes: 4_096)
        let book = try await insertBookWithUserData(at: original)

        // Move to Trash: only the old path is inside the watched folder.
        let trash = tempDir.appendingPathComponent("Trash/Dune.epub")
        try FileManager.default.createDirectory(
            at: trash.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.moveItem(at: original, to: trash)
        let trashed = await plan([FileEvent(path: original.path, flags: renamed, fileID: try inode(of: trash))])
        XCTAssertEqual(trashed.missing, [book.id])
        XCTAssertEqual(trashed.relocations, [])
        XCTAssertEqual(trashed.imports, [])
        let annotationsWhileTrashed = try await annotationRepo.annotationCount(forBook: book.id)
        XCTAssertEqual(annotationsWhileTrashed, 1)

        // Put Back: the file returns to its recorded path.
        try FileManager.default.moveItem(at: trash, to: original)
        let restored = await plan([FileEvent(path: original.path, flags: renamed)])
        XCTAssertEqual(restored.reappeared, [book.id])
        XCTAssertEqual(restored.relocations, [])
        XCTAssertEqual(restored.imports, [])
        try await assertUserDataIntact(for: book, nowAt: original)
    }

    // MARK: - New files and ambiguity

    func testUnrelatedNewFileIsImportedNotAdopted() async throws {
        let original = try writeFile("Dune.epub", bytes: 4_096)
        let book = try await insertBookWithUserData(at: original)
        try FileManager.default.removeItem(at: original)

        let newBook = try writeFile("Foundation.epub", bytes: 9_999, seed: 2)
        let result = await plan([
            FileEvent(path: original.path),
            FileEvent(path: newBook.path, fileID: try inode(of: newBook)),
        ])

        XCTAssertEqual(result.relocations, [])
        XCTAssertEqual(result.imports, [newBook.path])
        XCTAssertEqual(result.missing, [book.id])
    }

    func testAmbiguousCandidatesAreNotGuessed() async throws {
        // Two missing books of identical size and format; a third name
        // appears. Without an inode there's no way to tell which one it is,
        // so it's imported as new and both missing rows are kept.
        let a = try writeFile("A.epub", bytes: 2_000)
        let b = try writeFile("B.epub", bytes: 2_000)
        let bookA = try await insertBookWithUserData(at: a)
        let bookB = Book(filePath: b.path, fileName: "B.epub", format: .epub, fileSize: 2_000)
        try await bookRepo.insertBook(bookB)
        try FileManager.default.removeItem(at: a)
        let c = try move(b, to: "C.epub")

        let result = await plan([
            FileEvent(path: a.path),
            FileEvent(path: b.path),
            FileEvent(path: c.path),
        ])

        XCTAssertEqual(result.relocations, [])
        XCTAssertEqual(result.imports, [c.path])
        XCTAssertEqual(Set(result.missing), [bookA.id, bookB.id])
    }

    func testInodeEvidenceBeatsNameMatch() {
        let renamedBook = Book(filePath: "/L/Old Name.epub", fileName: "Old Name.epub", format: .epub, fileSize: 100)
        let sameNameBook = Book(filePath: "/Elsewhere/New.epub", fileName: "New.epub", format: .epub, fileSize: 100)
        let appeared = BookRelocationPlanner.AppearedFile(path: "/L/New.epub", fileSize: 100, format: .epub, fileID: 7)

        let relocations = BookRelocationPlanner.match(
            appeared: [appeared],
            missing: [
                .init(book: sameNameBook, eventFileIDs: [], reportedInBatch: false),
                .init(book: renamedBook, eventFileIDs: [7], reportedInBatch: true),
            ]
        )

        XCTAssertEqual(relocations, [.init(bookID: renamedBook.id, newPath: "/L/New.epub", fileSize: 100)])
    }

    func testFormatMustMatchForHeuristicTiers() {
        let pdf = Book(filePath: "/L/Dune.pdf", fileName: "Dune.pdf", format: .pdf, fileSize: 100)
        let appeared = BookRelocationPlanner.AppearedFile(path: "/M/Dune.epub", fileSize: 100, format: .epub, fileID: nil)

        let relocations = BookRelocationPlanner.match(
            appeared: [appeared],
            missing: [.init(book: pdf, eventFileIDs: [], reportedInBatch: true)]
        )

        XCTAssertEqual(relocations, [])
    }

    // MARK: - Delete confirmation counts

    func testAnnotationCountsForDeleteConfirmation() async throws {
        let inside = try writeFile("Sub/Dune.epub", bytes: 1_000)
        let book = try await insertBookWithUserData(at: inside)
        let outsideDir = tempDir.appendingPathComponent("Library-Archive", isDirectory: true)
        let outside = Book(filePath: outsideDir.appendingPathComponent("X.epub").path, fileName: "X.epub", format: .epub, fileSize: 1)
        try await bookRepo.insertBook(outside)
        try await annotationRepo.insertAnnotation(Annotation(
            bookId: outside.id,
            tool: .underline,
            position: .pdf(pageIndex: 0, bounds: nil)
        ))

        let forBooks = try await annotationRepo.annotationCount(forBooks: [book.id, outside.id])
        XCTAssertEqual(forBooks, 2)
        let inFolder = try await annotationRepo.annotationCount(inFolder: libraryDir.path)
        XCTAssertEqual(inFolder, 1, "a sibling folder sharing the prefix must not be counted")
    }

    func testDeletionMessageStatesAnnotationLoss() {
        XCTAssertTrue(
            AppState.deletionMessage(annotationCount: 12, filesNote: "").contains("12 annotations will be permanently deleted")
        )
        XCTAssertTrue(
            AppState.deletionMessage(annotationCount: 1, filesNote: "").contains("1 annotation will be permanently deleted")
        )
        XCTAssertTrue(
            AppState.deletionMessage(annotationCount: 0, filesNote: "").contains("No annotations will be lost")
        )
    }

    // MARK: - Debug builds never open the real library

    func testDebugBuildUsesSeparateDatabaseFile() {
        XCTAssertNotEqual(DatabaseManager.debugDatabaseFileName, DatabaseManager.productionDatabaseFileName)
        #if DEBUG
        XCTAssertEqual(DatabaseManager.databaseFileName, DatabaseManager.debugDatabaseFileName)
        #else
        XCTAssertEqual(DatabaseManager.databaseFileName, DatabaseManager.productionDatabaseFileName)
        #endif
    }
}
