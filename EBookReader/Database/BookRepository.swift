import Foundation
import GRDB
import os

actor BookRepository {
    // Internal so AppState can start ValueObservations directly on the main actor.
    let dbPool: DatabasePool
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "EBookReader",
        category: "BookRepository"
    )

    init(dbPool: DatabasePool) {
        self.dbPool = dbPool
    }

    // MARK: - Books

    func fetchAllBooks(orderedBy column: Book.Columns = .title, ascending: Bool = true) throws -> [Book] {
        try dbPool.read { db in
            try Book
                .order(ascending ? column.asc : column.desc)
                .fetchAll(db)
        }
    }

    func fetchBook(id: UUID) throws -> Book? {
        try dbPool.read { db in
            try Book.fetchOne(db, key: id)
        }
    }

    func fetchBook(byPath path: String) throws -> Book? {
        try dbPool.read { db in
            try Book.filter(Book.Columns.filePath == path).fetchOne(db)
        }
    }

    func bookExists(atPath path: String) throws -> Bool {
        try dbPool.read { db in
            try Book.filter(Book.Columns.filePath == path).fetchCount(db) > 0
        }
    }

    @discardableResult
    func insertBook(_ book: Book) throws -> Book {
        try dbPool.write { db in
            var book = book
            try book.insert(db)
            return book
        }
    }

    func insertBooks(_ books: [Book]) throws {
        try dbPool.write { db in
            for var book in books {
                try book.insert(db, onConflict: .ignore)
            }
        }
    }

    func updateBook(_ book: Book) throws {
        try dbPool.write { db in
            let book = book
            try book.update(db)
        }
    }

    func updateLastReadPosition(bookId: UUID, position: String) throws {
        try dbPool.write { db in
            try db.execute(
                sql: "UPDATE book SET lastReadPosition = ?, dateLastOpened = ? WHERE id = ?",
                arguments: [position, Date(), bookId]
            )
        }
    }

    func markThumbnailCached(bookId: UUID) throws {
        try dbPool.write { db in
            try db.execute(
                sql: "UPDATE book SET hasCachedThumbnail = 1 WHERE id = ?",
                arguments: [bookId]
            )
        }
    }

    func deleteBook(id: UUID) throws {
        try dbPool.write { db in
            _ = try Book.deleteOne(db, key: id)
        }
    }

    func deleteBooksInFolder(_ folderPath: String) throws {
        // Normalize: ensure trailing "/" so /Books/SciFi doesn't match /Books/SciFi-Archive
        let normalized = folderPath.hasSuffix("/") ? folderPath : folderPath + "/"
        _ = try dbPool.write { db in
            try Book
                .filter(Book.Columns.filePath.like("\(normalized)%"))
                .deleteAll(db)
        }
    }

    func fetchRecentlyOpened(limit: Int = 50) throws -> [Book] {
        try dbPool.read { db in
            try Book
                .filter(Book.Columns.dateLastOpened != nil)
                .order(Book.Columns.dateLastOpened.desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    func fetchBooks(withFormat format: BookFormat) throws -> [Book] {
        try dbPool.read { db in
            try Book
                .filter(Book.Columns.format == format.rawValue)
                .order(Book.Columns.title.asc)
                .fetchAll(db)
        }
    }

    /// Batched lookup by ID set. Used by cookbook lifecycle to ensure every
    /// book in a collection has its embedding pipeline kicked off.
    func fetchBooks(byIds ids: [UUID]) throws -> [Book] {
        guard !ids.isEmpty else { return [] }
        return try dbPool.read { db in
            try Book.filter(ids.contains(Book.Columns.id)).fetchAll(db)
        }
    }

    func bookCount() throws -> Int {
        try dbPool.read { db in
            try Book.fetchCount(db)
        }
    }

    // MARK: - Watched Folders

    func fetchAllWatchedFolders() throws -> [WatchedFolder] {
        try dbPool.read { db in
            try WatchedFolder.order(WatchedFolder.Columns.dateAdded.asc).fetchAll(db)
        }
    }

    @discardableResult
    func insertWatchedFolder(_ folder: WatchedFolder) throws -> WatchedFolder {
        try dbPool.write { db in
            var folder = folder
            try folder.insert(db)
            return folder
        }
    }

    func watchedFolderExists(atPath path: String) throws -> Bool {
        try dbPool.read { db in
            try WatchedFolder.filter(WatchedFolder.Columns.path == path).fetchCount(db) > 0
        }
    }

    func fetchWatchedFolder(atPath path: String) throws -> WatchedFolder? {
        try dbPool.read { db in
            try WatchedFolder.filter(WatchedFolder.Columns.path == path).fetchOne(db)
        }
    }

    func fetchBooks(inFolder folderPath: String) throws -> [Book] {
        try dbPool.read { db in
            try Book
                .filter(Book.Columns.filePath.like("\(folderPath)/%"))
                .fetchAll(db)
        }
    }

    func countBooks(inFolder folderPath: String) throws -> Int {
        try dbPool.read { db in
            try Book
                .filter(Book.Columns.filePath.like("\(folderPath)/%"))
                .fetchCount(db)
        }
    }

    func deleteWatchedFolder(id: UUID) throws {
        try dbPool.write { db in
            _ = try WatchedFolder.deleteOne(db, key: id)
        }
    }

    func updateWatchedFolderBookmark(id: UUID, bookmarkData: Data) throws {
        try dbPool.write { db in
            try db.execute(
                sql: "UPDATE watchedFolder SET bookmarkData = ? WHERE id = ?",
                arguments: [bookmarkData, id]
            )
        }
    }

}
