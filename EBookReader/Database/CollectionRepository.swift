import Foundation
import GRDB
import os

actor CollectionRepository {
    let dbPool: DatabasePool
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "EBookReader",
        category: "CollectionRepository"
    )

    init(dbPool: DatabasePool) {
        self.dbPool = dbPool
    }

    // MARK: - Collection Groups

    func fetchAllGroups() throws -> [CollectionGroup] {
        try dbPool.read { db in
            try CollectionGroup
                .order(CollectionGroup.Columns.sortOrder.asc)
                .fetchAll(db)
        }
    }

    @discardableResult
    func insertGroup(_ group: CollectionGroup) throws -> CollectionGroup {
        try dbPool.write { db in
            var group = group
            try group.insert(db)
            return group
        }
    }

    func updateGroup(_ group: CollectionGroup) throws {
        try dbPool.write { db in
            try group.update(db)
        }
    }

    func deleteGroup(id: UUID) throws {
        try dbPool.write { db in
            _ = try CollectionGroup.deleteOne(db, key: id)
        }
    }

    func nextGroupSortOrder() throws -> Int {
        try dbPool.read { db in
            let max = try Int.fetchOne(
                db,
                sql: "SELECT COALESCE(MAX(sortOrder), -10) FROM collectionGroup"
            ) ?? 0
            return max + 10
        }
    }

    // MARK: - Collections

    func fetchAllCollections() throws -> [Collection] {
        try dbPool.read { db in
            try Collection
                .order(Collection.Columns.sortOrder.asc)
                .fetchAll(db)
        }
    }

    func fetchCollections(inGroup groupId: UUID) throws -> [Collection] {
        try dbPool.read { db in
            try Collection
                .filter(Collection.Columns.collectionGroupId == groupId)
                .order(Collection.Columns.sortOrder.asc)
                .fetchAll(db)
        }
    }

    func fetchUngroupedCollections() throws -> [Collection] {
        try dbPool.read { db in
            try Collection
                .filter(Collection.Columns.collectionGroupId == nil)
                .order(Collection.Columns.sortOrder.asc)
                .fetchAll(db)
        }
    }

    @discardableResult
    func insertCollection(_ collection: Collection) throws -> Collection {
        try dbPool.write { db in
            var collection = collection
            try collection.insert(db)
            return collection
        }
    }

    func updateCollection(_ collection: Collection) throws {
        try dbPool.write { db in
            try collection.update(db)
        }
    }

    func deleteCollection(id: UUID) throws {
        try dbPool.write { db in
            // bookCollection entries are cascade-deleted
            _ = try Collection.deleteOne(db, key: id)
        }
    }

    func moveCollection(id: UUID, toGroup groupId: UUID?) throws {
        try dbPool.write { db in
            try db.execute(
                sql: "UPDATE collection SET collectionGroupId = ? WHERE id = ?",
                arguments: [groupId, id]
            )
        }
    }

    func nextCollectionSortOrder(inGroup groupId: UUID? = nil) throws -> Int {
        try dbPool.read { db in
            let sql: String
            let arguments: StatementArguments
            if let groupId {
                sql = "SELECT COALESCE(MAX(sortOrder), -10) FROM collection WHERE collectionGroupId = ?"
                arguments = [groupId]
            } else {
                sql = "SELECT COALESCE(MAX(sortOrder), -10) FROM collection WHERE collectionGroupId IS NULL"
                arguments = []
            }
            let max = try Int.fetchOne(db, sql: sql, arguments: arguments) ?? 0
            return max + 10
        }
    }

    // MARK: - Book ↔ Collection

    func addBook(_ bookId: UUID, toCollection collectionId: UUID) throws {
        try dbPool.write { db in
            var entry = BookCollection(bookId: bookId, collectionId: collectionId)
            try entry.insert(db, onConflict: .ignore)
        }
    }

    func addBooks(_ bookIds: [UUID], toCollection collectionId: UUID) throws {
        try dbPool.write { db in
            for bookId in bookIds {
                var entry = BookCollection(bookId: bookId, collectionId: collectionId)
                try entry.insert(db, onConflict: .ignore)
            }
        }
    }

    func removeBook(_ bookId: UUID, fromCollection collectionId: UUID) throws {
        try dbPool.write { db in
            try db.execute(
                sql: "DELETE FROM bookCollection WHERE bookId = ? AND collectionId = ?",
                arguments: [bookId, collectionId]
            )
        }
    }

    func fetchBookIDs(inCollection collectionId: UUID) throws -> [UUID] {
        try dbPool.read { db in
            try UUID.fetchAll(
                db,
                sql: "SELECT bookId FROM bookCollection WHERE collectionId = ? ORDER BY dateAdded",
                arguments: [collectionId]
            )
        }
    }

    func fetchBooks(inCollection collectionId: UUID) throws -> [Book] {
        try dbPool.read { db in
            try Book.fetchAll(
                db,
                sql: """
                    SELECT book.* FROM book
                    JOIN bookCollection ON book.id = bookCollection.bookId
                    WHERE bookCollection.collectionId = ?
                    ORDER BY book.title ASC
                    """,
                arguments: [collectionId]
            )
        }
    }

    func bookCount(inCollection collectionId: UUID) throws -> Int {
        try dbPool.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM bookCollection WHERE collectionId = ?",
                arguments: [collectionId]
            ) ?? 0
        }
    }
}
