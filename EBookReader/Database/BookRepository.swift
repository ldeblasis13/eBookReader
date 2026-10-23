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
    /// its folder doesn't import it again (see `exclusion(forDeleting:)`).
    /// The row is read here, not taken from the caller, whose copy may
    /// predate a relocation; nothing is recorded unless the row was deleted.
    func deleteBookExcludingFile(id: UUID) throws {
        guard let book = try fetchBook(id: id) else { return }
        var spellings: [String: String] = [:]
        let exclusion = try Self.exclusion(
            forDeleting: book.filePath,
            recordedSize: book.fileSize,
            watchedRoot: fullImportFolderPath(containing: book.filePath),
            directorySpellings: &spellings
        )
        try dbPool.write { db in
            guard try Book.deleteOne(db, key: id) else { return }
            try exclusion?.save(db)
        }
    }

    /// Deletes the books that go with `folderPath` when it's removed: the
    /// ones under it (only that folder: /Books/SciFi leaves
    /// /Books/SciFi-Archive and /Books/scifi alone), except books under
    /// another watched folder nested inside it, which stays watched.
    ///
    /// The removed folder's exclusions go with it — unless it sits inside
    /// another full-import folder, whose reconcile would import the books
    /// again. Then they're recorded as excluded instead, as for Delete from
    /// Library.
    func deleteBooksInFolder(_ folderPath: String) throws {
        let books = FolderPathRange(folderPath).removalScope(column: "book.filePath")
        let exclusions = FolderPathRange(folderPath).removalScope(column: "excludedBookFile.path")

        let outerRoot = try fullImportFolderPath(containing: folderPath)
        let insideWatchedFolder = outerRoot != nil
        var recorded: [ExcludedBookFile] = []
        if insideWatchedFolder {
            let rows = try dbPool.read { db in
                try Row.fetchAll(
                    db,
                    Book.select(Book.Columns.filePath, Book.Columns.fileSize).filter(sql: books.sql, arguments: books.arguments)
                )
            }
            var spellings: [String: String] = [:]
            recorded = rows.compactMap { row in
                Self.exclusion(
                    forDeleting: row[Book.Columns.filePath],
                    recordedSize: row[Book.Columns.fileSize],
                    watchedRoot: outerRoot,
                    directorySpellings: &spellings
                )
            }
        }

        try dbPool.write { db in
            if insideWatchedFolder {
                for exclusion in recorded { try exclusion.save(db) }
            } else {
                _ = try ExcludedBookFile.filter(sql: exclusions.sql, arguments: exclusions.arguments).deleteAll(db)
            }
            _ = try Book.filter(sql: books.sql, arguments: books.arguments).deleteAll(db)
        }
    }

    // MARK: - Excluded Files

    /// Recorded size for each of `paths` the user deleted from the library.
    /// An exclusion only holds back a file at that path with that size.
    func exclusionSizes(forPaths paths: [String]) throws -> [String: Int64] {
        try dbPool.read { db in
            var sizes: [String: Int64] = [:]
            for start in stride(from: 0, to: paths.count, by: 500) {
                let chunk = paths[start..<min(start + 500, paths.count)]
                for exclusion in try ExcludedBookFile.filter(chunk.contains(ExcludedBookFile.Columns.path)).fetchAll(db) {
                    sizes[exclusion.path] = exclusion.fileSize
                }
            }
            return sizes
        }
    }

    /// Paths of the exclusions anywhere under `folderPath`.
    func exclusionPaths(inside folderPath: String) throws -> [String] {
        try dbPool.read { db in
            try String.fetchAll(
                db,
                ExcludedBookFile
                    .select(ExcludedBookFile.Columns.path)
                    .filter(FolderPathRange(folderPath).contains(ExcludedBookFile.Columns.path))
            )
        }
    }

    /// A watched folder's first reconcile after upgrading (it has
    /// `needsExclusionSeed`). Books deleted before exclusions were recorded
    /// left no trace, so the files that reconcile would import are taken to
    /// be deleted — as before the upgrade, they come back when the folder or
    /// the file is added again. Records the ones still on disk and, if the
    /// walk saw the whole folder, clears the flag, in one transaction; after
    /// a walk that couldn't reach it all (an ejected drive) the next
    /// reconcile seeds again.
    ///
    /// The flag is checked in that transaction too: Add Folder may have
    /// cleared it while the reconcile ran. Then nothing is recorded and this
    /// returns false — the caller should import `paths` instead.
    @discardableResult
    func seedExclusions(forFolder folderID: UUID, paths: [String], walkedWholeFolder: Bool) throws -> Bool {
        let exclusions = paths.compactMap { Self.exclusion(forFileAt: $0) }
        return try dbPool.write { db in
            guard try WatchedFolder.fetchOne(db, key: folderID)?.needsExclusionSeed == true else { return false }
            for exclusion in exclusions { try exclusion.save(db) }
            if walkedWholeFolder {
                _ = try WatchedFolder.filter(key: folderID).updateAll(db, WatchedFolder.Columns.needsExclusionSeed.set(to: false))
            }
            return true
        }
    }

    /// An exclusion for the file at `path` as it is now, if it's there.
    private static func exclusion(forFileAt path: String) -> ExcludedBookFile? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = (attributes[.size] as? NSNumber)?.int64Value
        else { return nil }
        return ExcludedBookFile(path: path, fileSize: size)
    }

    /// What to record for a book file the user deletes from the library:
    /// - still on disk: its current size, at the path a folder walk reports
    ///   (see `onDiskSpelling`);
    /// - gone while its watched folder can't be reached (an ejected drive):
    ///   the size recorded for the row, or the book would come back with the
    ///   drive;
    /// - gone from a watched folder that's there, or outside every one:
    ///   nothing — no reconcile would bring it back.
    private static func exclusion(
        forDeleting path: String,
        recordedSize: Int64,
        watchedRoot: String?,
        directorySpellings: inout [String: String]
    ) -> ExcludedBookFile? {
        if let onDisk = exclusion(forFileAt: path) {
            return ExcludedBookFile(
                path: onDiskSpelling(of: path, below: watchedRoot, directories: &directorySpellings),
                fileSize: onDisk.fileSize
            )
        }
        guard let watchedRoot, !FileManager.default.fileExists(atPath: watchedRoot) else { return nil }
        return ExcludedBookFile(path: path, fileSize: recordedSize)
    }

    /// `path` as the file system spells it below `root`. On a
    /// case-insensitive volume a row can still say "sci-fi/dune.epub" for a
    /// file renamed "Sci-Fi/Dune.epub" that no reconcile has caught up with
    /// yet; walks report the new spelling. The root's own spelling is kept,
    /// since every path under it starts with it. `directories` caches
    /// directory spellings across calls.
    private static func onDiskSpelling(of path: String, below root: String?, directories: inout [String: String]) -> String {
        let name = (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.nameKey]).name)
            ?? (path as NSString).lastPathComponent
        let parent = (path as NSString).deletingLastPathComponent
        guard let root, parent != root, parent.hasPrefix(root.hasSuffix("/") ? root : root + "/") else {
            return (parent as NSString).appendingPathComponent(name)
        }
        let directory: String
        if let known = directories[parent] {
            directory = known
        } else {
            directory = onDiskSpelling(of: parent, below: root, directories: &directories)
            directories[parent] = directory
        }
        return (directory as NSString).appendingPathComponent(name)
    }

    /// The innermost full-import watched folder that `path` is inside.
    private func fullImportFolderPath(containing path: String) throws -> String? {
        try dbPool.read { db in
            try String.fetchOne(
                db,
                sql: """
                    SELECT path FROM watchedFolder
                    WHERE isFullImport AND ? >= path || '/' AND ? < path || '0'
                    ORDER BY length(path) DESC LIMIT 1
                    """,
                arguments: [path, path]
            )
        }
    }

    /// Forgets exclusions for these paths: the file is gone or replaced, a
    /// missing book was relocated there, or the user added it explicitly.
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
            // An explicit add imports everything, so there's nothing to seed.
            folder.needsExclusionSeed = false
            guard !folder.isFullImport else {
                try folder.update(db)
                return .alreadyWatched
            }
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

    /// Books removing `folderPath` would delete (see `deleteBooksInFolder`).
    func countBooks(inFolder folderPath: String) throws -> Int {
        let scope = FolderPathRange(folderPath).removalScope(column: "book.filePath")
        return try dbPool.read { db in
            try Book.filter(sql: scope.sql, arguments: scope.arguments).fetchCount(db)
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

    /// SQL for "`column` is inside the folder but not inside another watched
    /// folder nested in it": what removing the folder takes with it, since a
    /// nested watched folder stays in the library. `column` must be
    /// table-qualified ("book.filePath"): a bare `path` would resolve to the
    /// subquery's watchedFolder.path.
    func removalScope(column: String) -> (sql: String, arguments: StatementArguments) {
        (
            sql: """
                \(column) >= ? AND \(column) < ? AND NOT EXISTS (
                    SELECT 1 FROM watchedFolder AS nested
                    WHERE nested.path >= ? AND nested.path < ?
                      AND \(column) >= nested.path || '/' AND \(column) < nested.path || '0')
                """,
            arguments: [lowerBound, upperBound, lowerBound, upperBound]
        )
    }
}
