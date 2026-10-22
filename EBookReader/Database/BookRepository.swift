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

    /// Points an existing book at its file's new location after a rename or
    /// move. The row — and with it the book's annotations, collections,
    /// reading position and embeddings — is kept; only path, name and size change.
    @discardableResult
    func relocateBook(id: UUID, toPath newPath: String, fileSize: Int64) throws -> Bool {
        try dbPool.write { db in
            try Book.filter(key: id).updateAll(
                db,
                Book.Columns.filePath.set(to: newPath),
                Book.Columns.fileName.set(to: URL(fileURLWithPath: newPath).lastPathComponent),
                Book.Columns.fileSize.set(to: fileSize)
            ) > 0
        }
    }

    /// Path → id for every book whose file is anywhere under `folderPath`.
    /// Used to diff a folder against what's on disk, so it reads only those
    /// two columns. A range on filePath rather than LIKE: LIKE is
    /// case-insensitive and treats `_` and `%` in folder names as
    /// wildcards, and the range can use the filePath index.
    func fetchBookIDsByPath(under folderPath: String) throws -> [String: UUID] {
        let prefix = folderPath.hasSuffix("/") ? folderPath : folderPath + "/"
        // Every path starting with "…/" sorts before "…0" ("0" follows "/").
        let upperBound = String(prefix.dropLast()) + "0"
        return try dbPool.read { db in
            var idsByPath: [String: UUID] = [:]
            let rows = try Row.fetchCursor(
                db,
                sql: "SELECT id, filePath FROM book WHERE filePath >= ? AND filePath < ?",
                arguments: [prefix, upperBound]
            )
            while let row = try rows.next() {
                idsByPath[row["filePath"]] = row["id"]
            }
            return idsByPath
        }
    }

    /// The subset of `paths` that already have a book row.
    func existingBookPaths(among paths: [String]) throws -> Set<String> {
        try dbPool.read { db in
            var existing = Set<String>()
            for start in stride(from: 0, to: paths.count, by: 500) {
                let chunk = paths[start..<min(start + 500, paths.count)]
                let found = try String.fetchAll(
                    db,
                    Book.select(Book.Columns.filePath).filter(chunk.contains(Book.Columns.filePath))
                )
                existing.formUnion(found)
            }
            return existing
        }
    }

    /// Books with any of the given file sizes — candidates when matching a
    /// file that appeared to a book whose file went missing.
    func fetchBooks(withFileSizes sizes: Set<Int64>) throws -> [Book] {
        let sizes = Array(sizes)
        return try dbPool.read { db in
            var books: [Book] = []
            // Chunked to stay well under SQLite's bound-parameter limit.
            for start in stride(from: 0, to: sizes.count, by: 500) {
                let chunk = sizes[start..<min(start + 500, sizes.count)]
                books += try Book.filter(chunk.contains(Book.Columns.fileSize)).fetchAll(db)
            }
            return books
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
            var books: [Book] = []
            // Chunked to stay well under SQLite's bound-parameter limit.
            for start in stride(from: 0, to: ids.count, by: 500) {
                let chunk = ids[start..<min(start + 500, ids.count)]
                books += try Book.filter(chunk.contains(Book.Columns.id)).fetchAll(db)
            }
            return books
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
