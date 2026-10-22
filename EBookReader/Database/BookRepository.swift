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

    /// Points existing books at their files' new locations after renames or
    /// moves. The rows — and with them each book's annotations, collections,
    /// reading position and embeddings — are kept; only path, name and size
    /// change.
    ///
    /// Applies relocations in a few transactions (500 per write) rather than
    /// one write each, so renaming a big folder wakes the library
    /// observation a handful of times instead of once per book. A
    /// relocation that would collide with another row's path (UNIQUE
    /// filePath) is skipped; skipped ones are retried after the rest, so a
    /// chain like a→b, b→c still lands. Returns the relocations applied.
    func relocateBooks(_ relocations: [BookRelocationPlanner.Relocation]) throws -> [BookRelocationPlanner.Relocation] {
        var pending = relocations
        var applied: [BookRelocationPlanner.Relocation] = []
        while !pending.isEmpty {
            var collided: [BookRelocationPlanner.Relocation] = []
            for start in stride(from: 0, to: pending.count, by: 500) {
                let chunk = Array(pending[start..<min(start + 500, pending.count)])
                let (done, failed) = try dbPool.write { db in
                    var done: [BookRelocationPlanner.Relocation] = []
                    var failed: [BookRelocationPlanner.Relocation] = []
                    for relocation in chunk {
                        do {
                            let changed = try Book.filter(key: relocation.bookID).updateAll(
                                db,
                                Book.Columns.filePath.set(to: relocation.newPath),
                                Book.Columns.fileName.set(to: URL(fileURLWithPath: relocation.newPath).lastPathComponent),
                                Book.Columns.fileSize.set(to: relocation.fileSize)
                            )
                            if changed > 0 { done.append(relocation) }
                        } catch let error as DatabaseError where error.resultCode == .SQLITE_CONSTRAINT {
                            // Only this statement is rolled back; the transaction goes on.
                            failed.append(relocation)
                        }
                    }
                    return (done, failed)
                }
                applied += done
                collided += failed
            }
            guard collided.count < pending.count else { break }
            pending = collided
        }
        return applied
    }

    /// Path → id for every book whose file is anywhere under `folderPath`.
    /// Used to diff a folder against what's on disk, so it reads only those
    /// two columns.
    func fetchBookIDsByPath(under folderPath: String) throws -> [String: UUID] {
        let range = FolderPathRange(folderPath)
        return try dbPool.read { db in
            var idsByPath: [String: UUID] = [:]
            let rows = try Row.fetchCursor(
                db,
                sql: "SELECT id, filePath FROM book WHERE filePath >= ? AND filePath < ?",
                arguments: [range.lowerBound, range.upperBound]
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

    /// Deletes a book row and records its file as excluded, so reconciling
    /// its folder with disk doesn't import it again.
    func deleteBookExcludingFile(_ book: Book) throws {
        try dbPool.write { db in
            try ExcludedBookFile(path: book.filePath, fileSize: book.fileSize).save(db)
            _ = try Book.deleteOne(db, key: book.id)
        }
    }

    /// Deletes every book under `folderPath` (only that folder: /Books/SciFi
    /// leaves /Books/SciFi-Archive and /Books/scifi alone).
    ///
    /// Normally the folder's excluded files are forgotten along with it. If
    /// the folder sits inside another watched folder, that folder's
    /// reconcile would import the books again, so pass `recordingExclusions`
    /// to remember them as deleted instead.
    func deleteBooksInFolder(_ folderPath: String, recordingExclusions: Bool = false) throws {
        let range = FolderPathRange(folderPath)
        try dbPool.write { db in
            if recordingExclusions {
                try db.execute(
                    sql: """
                        INSERT OR REPLACE INTO excludedBookFile (path, fileSize, dateExcluded)
                        SELECT filePath, fileSize, ? FROM book WHERE filePath >= ? AND filePath < ?
                        """,
                    arguments: [Date(), range.lowerBound, range.upperBound]
                )
            } else {
                _ = try ExcludedBookFile.filter(range.contains(ExcludedBookFile.Columns.path)).deleteAll(db)
            }
            _ = try Book.filter(range.contains(Book.Columns.filePath)).deleteAll(db)
        }
    }

    // MARK: - Excluded Files

    /// The subset of `paths` the user deleted from the library.
    func excludedPaths(among paths: [String]) throws -> Set<String> {
        try dbPool.read { db in
            var excluded = Set<String>()
            for start in stride(from: 0, to: paths.count, by: 500) {
                let chunk = paths[start..<min(start + 500, paths.count)]
                let found = try String.fetchAll(
                    db,
                    ExcludedBookFile
                        .select(ExcludedBookFile.Columns.path)
                        .filter(chunk.contains(ExcludedBookFile.Columns.path))
                )
                excluded.formUnion(found)
            }
            return excluded
        }
    }

    /// Excluded files with any of the given sizes — so an excluded file that
    /// was renamed or moved can be recognised at its new path.
    func fetchExclusions(withFileSizes sizes: Set<Int64>) throws -> [ExcludedBookFile] {
        let sizes = Array(sizes)
        return try dbPool.read { db in
            var exclusions: [ExcludedBookFile] = []
            for start in stride(from: 0, to: sizes.count, by: 500) {
                let chunk = sizes[start..<min(start + 500, sizes.count)]
                exclusions += try ExcludedBookFile.filter(chunk.contains(ExcludedBookFile.Columns.fileSize)).fetchAll(db)
            }
            return exclusions
        }
    }

    /// Points exclusions at their files' new paths.
    func moveExclusions(_ moves: [BookRelocationPlanner.ExclusionMove]) throws {
        guard !moves.isEmpty else { return }
        try dbPool.write { db in
            for move in moves {
                _ = try ExcludedBookFile
                    .filter(ExcludedBookFile.Columns.path == move.oldPath)
                    .updateAll(db, onConflict: .replace, ExcludedBookFile.Columns.path.set(to: move.newPath))
            }
        }
    }

    /// Forgets exclusions for these files: the user added them explicitly.
    func clearExclusions(forPaths paths: [String]) throws {
        guard !paths.isEmpty else { return }
        try dbPool.write { db in
            for start in stride(from: 0, to: paths.count, by: 500) {
                let chunk = paths[start..<min(start + 500, paths.count)]
                _ = try ExcludedBookFile.filter(chunk.contains(ExcludedBookFile.Columns.path)).deleteAll(db)
            }
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

    enum FolderRegistration: Equatable, Sendable {
        case added
        /// Already a full-import folder.
        case alreadyWatched
        /// Was a partial-import folder (books added one by one); now full import.
        case upgradedFromPartialImport
    }

    /// Records `path` as a full-import watched folder — the user chose Add
    /// Folder. A partial-import entry for the same folder (left by Add
    /// Books) is upgraded in place. Adding a folder explicitly also brings
    /// back any of its files the user had deleted from the library.
    func registerFullImportFolder(path: String, bookmarkData: Data) throws -> FolderRegistration {
        try dbPool.write { db in
            _ = try ExcludedBookFile
                .filter(FolderPathRange(path).contains(ExcludedBookFile.Columns.path))
                .deleteAll(db)

            guard var folder = try WatchedFolder.filter(WatchedFolder.Columns.path == path).fetchOne(db) else {
                var folder = WatchedFolder(path: path, bookmarkData: bookmarkData)
                try folder.insert(db)
                return .added
            }
            guard !folder.isFullImport else { return .alreadyWatched }
            folder.isFullImport = true
            folder.bookmarkData = bookmarkData
            try folder.update(db)
            return .upgradedFromPartialImport
        }
    }

    func fetchBooks(inFolder folderPath: String) throws -> [Book] {
        try dbPool.read { db in
            try Book
                .filter(FolderPathRange(folderPath).contains(Book.Columns.filePath))
                .fetchAll(db)
        }
    }

    func countBooks(inFolder folderPath: String) throws -> Int {
        try dbPool.read { db in
            try Book
                .filter(FolderPathRange(folderPath).contains(Book.Columns.filePath))
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

/// File paths anywhere inside a folder, as a half-open range on a path
/// column: an exact, case-sensitive prefix match that can use the column's
/// index. (LIKE ignores ASCII case and treats `_` and `%` in folder names
/// as wildcards, so removing /x/E_Books would also hit /x/EXBooks.)
struct FolderPathRange: Sendable {
    /// "folder/"
    let lowerBound: String
    /// "folder0": every path starting with "folder/" sorts below it, since
    /// "0" comes right after "/".
    let upperBound: String

    init(_ folderPath: String) {
        lowerBound = folderPath.hasSuffix("/") ? folderPath : folderPath + "/"
        upperBound = String(lowerBound.dropLast()) + "0"
    }

    func contains(_ column: some SQLSpecificExpressible) -> SQLExpression {
        column >= lowerBound && column < upperBound
    }
}
