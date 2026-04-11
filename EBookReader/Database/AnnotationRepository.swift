import Foundation
import GRDB
import os

actor AnnotationRepository {
    let dbPool: DatabasePool
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "EBookReader",
        category: "AnnotationRepository"
    )

    init(dbPool: DatabasePool) {
        self.dbPool = dbPool
    }

    // MARK: - Fetch

    func fetchAnnotations(forBook bookId: UUID) throws -> [Annotation] {
        try dbPool.read { db in
            try Annotation
                .filter(Annotation.Columns.bookId == bookId)
                .order(Annotation.Columns.dateCreated.asc)
                .fetchAll(db)
        }
    }

    func fetchAnnotation(id: UUID) throws -> Annotation? {
        try dbPool.read { db in
            try Annotation.fetchOne(db, key: id)
        }
    }

    func fetchAnnotations(forBook bookId: UUID, tool: AnnotationTool) throws -> [Annotation] {
        try dbPool.read { db in
            try Annotation
                .filter(Annotation.Columns.bookId == bookId)
                .filter(Annotation.Columns.tool == tool.rawValue)
                .order(Annotation.Columns.dateCreated.asc)
                .fetchAll(db)
        }
    }

    func annotationCount(forBook bookId: UUID) throws -> Int {
        try dbPool.read { db in
            try Annotation
                .filter(Annotation.Columns.bookId == bookId)
                .fetchCount(db)
        }
    }

    // MARK: - Insert

    @discardableResult
    func insertAnnotation(_ annotation: Annotation) throws -> Annotation {
        try dbPool.write { db in
            var annotation = annotation
            try annotation.insert(db)
            return annotation
        }
    }

    // MARK: - Update

    func updateAnnotation(_ annotation: Annotation) throws {
        try dbPool.write { db in
            var updated = annotation
            updated.dateModified = Date()
            try updated.update(db)
        }
    }

    func updateColor(id: UUID, color: AnnotationColor) throws {
        try dbPool.write { db in
            try db.execute(
                sql: "UPDATE annotation SET color = ?, dateModified = ? WHERE id = ?",
                arguments: [color.rawValue, Date(), id]
            )
        }
    }

    func updateNote(id: UUID, note: String?) throws {
        try dbPool.write { db in
            try db.execute(
                sql: "UPDATE annotation SET note = ?, dateModified = ? WHERE id = ?",
                arguments: [note, Date(), id]
            )
        }
    }

    // MARK: - Delete

    func deleteAnnotation(id: UUID) throws {
        try dbPool.write { db in
            _ = try Annotation.deleteOne(db, key: id)
        }
    }

    func deleteAllAnnotations(forBook bookId: UUID) throws {
        try dbPool.write { db in
            _ = try Annotation
                .filter(Annotation.Columns.bookId == bookId)
                .deleteAll(db)
        }
    }
}
