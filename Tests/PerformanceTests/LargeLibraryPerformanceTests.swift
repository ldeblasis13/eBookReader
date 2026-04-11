import XCTest
import GRDB
@testable import EBookReader

/// Stress tests validating performance targets with 100 000 synthetic book records.
///
/// Performance targets (from CLAUDE.md / requirements):
///   • Library launch    < 2 s       (DB fetch of all books)
///   • Search            < 500 ms    (in-memory tier-1 / tier-2)
///   • Import batch      < 60 s      (100 k inserts total)
///   • Memory delta      < 250 MB    during initial load (Book structs, no BLOBs)
final class LargeLibraryPerformanceTests: XCTestCase {

    static let bookCount = 100_000

    /// Temporary file-based database (DatabasePool requires WAL mode, unavailable for :memory:).
    private var tempDir: URL!
    private var dbPool: DatabasePool!
    private var repository: BookRepository!

    // MARK: - Setup / Teardown

    override func setUpWithError() throws {
        // Each test instance gets its own scratch directory so tests don't interfere.
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("EBookReaderPerfTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let dbPath = tempDir.appendingPathComponent("perf_test.sqlite").path
        dbPool = try DatabasePool(path: dbPath)
        try applySchema(dbPool)
        repository = BookRepository(dbPool: dbPool)
    }

    override func tearDownWithError() throws {
        repository = nil
        dbPool = nil
        // Clean up the scratch directory (best effort).
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
    }

    // MARK: - Schema (mirrors DatabaseManager, stable subset)

    private func applySchema(_ pool: DatabasePool) throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "book") { t in
                t.primaryKey("id", .text).notNull()
                t.column("filePath", .text).notNull().unique()
                t.column("fileName", .text).notNull()
                t.column("title", .text)
                t.column("author", .text)
                t.column("format", .text).notNull()
                t.column("fileSize", .integer).notNull()
                t.column("pageCount", .integer)
                t.column("language", .text)
                t.column("publisher", .text)
                t.column("isbn", .text)
                t.column("bookDescription", .text)
                t.column("coverImageData", .blob)     // present in v1, dropped in v5
                t.column("bookmarkData", .blob)
                t.column("dateAdded", .datetime).notNull()
                t.column("dateLastOpened", .datetime)
                t.column("lastReadPosition", .text)
                t.column("fullTextIndexed", .boolean).notNull().defaults(to: false)
            }
            try db.create(index: "idx_book_format",    on: "book", columns: ["format"])
            try db.create(index: "idx_book_title",     on: "book", columns: ["title"])
            try db.create(index: "idx_book_author",    on: "book", columns: ["author"])
            try db.create(index: "idx_book_dateAdded", on: "book", columns: ["dateAdded"])
        }
        migrator.registerMigration("v5") { db in
            try db.execute(sql: "ALTER TABLE book DROP COLUMN coverImageData")
            try db.alter(table: "book") { t in
                t.add(column: "hasCachedThumbnail", .boolean).notNull().defaults(to: false)
            }
        }
        try migrator.migrate(pool)
    }

    // MARK: - Synthetic Data Factory

    private static let formats: [BookFormat]  = BookFormat.allCases
    private static let authors: [String] = [
        "Jane Austen", "Leo Tolstoy", "Charles Dickens", "George Orwell",
        "Fyodor Dostoevsky", "Virginia Woolf", "Ernest Hemingway", "F. Scott Fitzgerald",
        "Gabriel García Márquez", "Toni Morrison"
    ]
    private static let publishers: [String?] = [
        "Penguin", "HarperCollins", "Random House", "Simon & Schuster", nil
    ]

    private func makeSyntheticBook(index: Int) -> Book {
        let format    = Self.formats[index % Self.formats.count]
        let author    = Self.authors[index % Self.authors.count]
        let publisher = Self.publishers[index % Self.publishers.count]
        return Book(
            filePath:           "/synthetic/library/book_\(index).\(format.fileExtension)",
            fileName:           "book_\(index).\(format.fileExtension)",
            title:              "Synthetic Book \(index)",
            author:             author,
            format:             format,
            fileSize:           Int64(1_024 * (index % 1_000 + 1)),
            pageCount:          (index % 500) + 10,
            language:           index % 10 == 0 ? "fr" : "en",
            publisher:          publisher,
            isbn:               index % 5 == 0 ? "978-3-16-\(String(format: "%08d", index))-0" : nil,
            bookDescription:    index % 20 == 0 ? "A compelling narrative about synthetic data." : nil,
            hasCachedThumbnail: index % 3 == 0
        )
    }

    /// Inserts 100 k books in batch-100 transactions.  Skips if already populated.
    private func populateLibrary() async throws {
        let count = try await repository.bookCount()
        guard count == 0 else { return }

        let batchSize = 100
        var batch: [Book] = []
        batch.reserveCapacity(batchSize)

        for i in 0..<Self.bookCount {
            batch.append(makeSyntheticBook(index: i))
            if batch.count == batchSize {
                try await repository.insertBooks(batch)
                batch.removeAll(keepingCapacity: true)
            }
        }
        if !batch.isEmpty {
            try await repository.insertBooks(batch)
        }
    }

    // MARK: - Insert Performance

    /// Bulk-inserts 100 k rows. Target: < 60 s (usually < 10 s on Apple Silicon).
    func testBulkInsert100kBooks() async throws {
        let start = Date()
        try await populateLibrary()
        let elapsed = Date().timeIntervalSince(start)

        let count = try await repository.bookCount()
        XCTAssertEqual(count, Self.bookCount, "Expected \(Self.bookCount) rows, got \(count)")
        XCTAssertLessThan(elapsed, 60,
            "100 k inserts took \(String(format: "%.2f", elapsed))s — exceeds 60 s budget")
        print("✅ 100 k inserts: \(String(format: "%.2f", elapsed))s")
    }

    // MARK: - Fetch Performance

    /// Fetches all 100 k rows. Target: < 2 s.
    func testFetchAll100kBooks() async throws {
        try await populateLibrary()

        let start = Date()
        let books = try await repository.fetchAllBooks(orderedBy: .title, ascending: true)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(books.count, Self.bookCount)
        XCTAssertLessThan(elapsed, 2.0,
            "fetchAllBooks took \(String(format: "%.2f", elapsed))s — exceeds 2 s target")
        print("✅ fetchAllBooks(\(books.count) rows): \(String(format: "%.2f", elapsed))s")
    }

    func testFetchByAuthorIndex() async throws {
        try await populateLibrary()

        let start = Date()
        let books = try await repository.fetchAllBooks(orderedBy: .author, ascending: true)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(books.count, Self.bookCount)
        XCTAssertLessThan(elapsed, 2.0,
            "fetch-by-author took \(String(format: "%.2f", elapsed))s")
        print("✅ fetchAllBooks(author ASC, \(books.count) rows): \(String(format: "%.2f", elapsed))s")
    }

    // MARK: - Search Performance

    /// Tier-1 + tier-2 in-memory search across 100 k Book objects. Target: < 500 ms.
    func testInMemorySearchPerformance() async throws {
        try await populateLibrary()
        let books = try await repository.fetchAllBooks()

        let start = Date()
        let results = inMemorySearch(query: "Tolstoy", books: books)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertFalse(results.isEmpty, "Expected results for 'Tolstoy'")
        XCTAssertLessThan(elapsed, 0.5,
            "In-memory search took \(String(format: "%.3f", elapsed))s — exceeds 500 ms target")
        print("✅ Search 'Tolstoy' in \(books.count) books: \(results.count) results, \(String(format: "%.3f", elapsed))s")
    }

    func testInMemorySearchMultipleQueries() async throws {
        try await populateLibrary()
        let books = try await repository.fetchAllBooks()

        let queries = ["Synthetic", "Austen", "book_999", "Penguin", "fr"]
        for query in queries {
            let start = Date()
            let results = inMemorySearch(query: query, books: books)
            let elapsed = Date().timeIntervalSince(start)
            XCTAssertLessThan(elapsed, 0.5, "Query '\(query)' took \(elapsed)s")
            print("  • '\(query)': \(results.count) results in \(String(format: "%.3f", elapsed))s")
        }
    }

    // MARK: - Memory Footprint

    /// Verifies that 100 k Book structs (no BLOBs) stay under the memory budget.
    func testMemoryFootprintOf100kBooks() async throws {
        try await populateLibrary()

        let before = currentMemoryUsageMB()
        let books = try await repository.fetchAllBooks()
        let after = currentMemoryUsageMB()
        let delta = after - before

        XCTAssertEqual(books.count, Self.bookCount)
        // Without the coverImageData BLOB each Book is ~500 bytes.
        // 100k × 500 B = ~50 MB raw; with Swift string overhead allow ≤ 250 MB.
        XCTAssertLessThan(delta, 250,
            "Loading \(books.count) books used ≈\(String(format: "%.0f", delta)) MB — exceeds 250 MB budget")
        print("✅ Memory delta for \(books.count) books: ≈\(String(format: "%.1f", delta)) MB")
    }

    // MARK: - Delete Performance

    /// Deletes all 100 k rows by folder path. Target: < 5 s.
    func testDeleteFolder100kBooks() async throws {
        try await populateLibrary()

        let start = Date()
        try await repository.deleteBooksInFolder("/synthetic/library")
        let elapsed = Date().timeIntervalSince(start)

        let remaining = try await repository.bookCount()
        XCTAssertEqual(remaining, 0, "Expected 0 rows after deletion, got \(remaining)")
        XCTAssertLessThan(elapsed, 5,
            "Deleting \(Self.bookCount) rows took \(String(format: "%.2f", elapsed))s — exceeds 5 s target")
        print("✅ Delete \(Self.bookCount) books: \(String(format: "%.2f", elapsed))s")
    }

    // MARK: - Xcode Measure (sync wrappers required by measure{})

    func testFetchAllMeasure() throws {
        try syncInsertLibrary()
        measure {
            _ = try? syncFetchAll()
        }
    }

    func testSearchMeasure() throws {
        try syncInsertLibrary()
        let books = try syncFetchAll()
        measure {
            _ = self.inMemorySearch(query: "Tolstoy", books: books)
        }
    }

    // MARK: - Private Helpers

    private func inMemorySearch(query: String, books: [Book]) -> [Book] {
        let q = query.lowercased()
        return books.filter { b in
            b.fileName.lowercased().contains(q) ||
            b.title?.lowercased().contains(q) == true ||
            b.author?.lowercased().contains(q) == true
        }
    }

    private func currentMemoryUsageMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        return Double(info.resident_size) / (1_024 * 1_024)
    }

    // MARK: - Sync helpers for `measure {}` blocks

    private func syncInsertLibrary() throws {
        let sema = DispatchSemaphore(value: 0)
        var err: Error?
        Task {
            do { try await self.populateLibrary() }
            catch { err = error }
            sema.signal()
        }
        sema.wait()
        if let e = err { throw e }
    }

    private func syncFetchAll() throws -> [Book] {
        let sema = DispatchSemaphore(value: 0)
        var result: [Book] = []
        var err: Error?
        Task {
            do { result = try await self.repository.fetchAllBooks() }
            catch { err = error }
            sema.signal()
        }
        sema.wait()
        if let e = err { throw e }
        return result
    }
}
