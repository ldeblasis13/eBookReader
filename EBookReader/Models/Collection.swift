import Foundation
import GRDB

struct Collection: Identifiable, Codable, Sendable, Hashable {
    var id: UUID
    var name: String
    var collectionGroupId: UUID?
    var sortOrder: Int
    var dateCreated: Date

    init(
        id: UUID = UUID(),
        name: String,
        collectionGroupId: UUID? = nil,
        sortOrder: Int = 0,
        dateCreated: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.collectionGroupId = collectionGroupId
        self.sortOrder = sortOrder
        self.dateCreated = dateCreated
    }
}

extension Collection: FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "collection"

    enum Columns: String, ColumnExpression {
        case id, name, collectionGroupId, sortOrder, dateCreated
    }
}

// MARK: - Collection Group

struct CollectionGroup: Identifiable, Codable, Sendable, Hashable {
    var id: UUID
    var name: String
    var sortOrder: Int
    var dateCreated: Date

    init(
        id: UUID = UUID(),
        name: String,
        sortOrder: Int = 0,
        dateCreated: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.sortOrder = sortOrder
        self.dateCreated = dateCreated
    }
}

extension CollectionGroup: FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "collectionGroup"

    enum Columns: String, ColumnExpression {
        case id, name, sortOrder, dateCreated
    }
}

// MARK: - Book ↔ Collection Join

struct BookCollection: Codable, Sendable, Hashable {
    var bookId: UUID
    var collectionId: UUID
    var dateAdded: Date

    init(bookId: UUID, collectionId: UUID, dateAdded: Date = Date()) {
        self.bookId = bookId
        self.collectionId = collectionId
        self.dateAdded = dateAdded
    }
}

extension BookCollection: FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "bookCollection"

    enum Columns: String, ColumnExpression {
        case bookId, collectionId, dateAdded
    }
}
