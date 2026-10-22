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

    /// Total annotations on the given books — shown before deleting them.
    func annotationCount(forBooks bookIds: [UUID]) throws -> Int {
        try dbPool.read { db in
            var total = 0
            // Chunked to stay well under SQLite's bound-parameter limit.
            for start in stride(from: 0, to: bookIds.count, by: 500) {
                let chunk = bookIds[start..<min(start + 500, bookIds.count)]
                total += try Annotation
                    .filter(chunk.contains(Annotation.Columns.bookId))
                    .fetchCount(db)
            }
            return total
        }
    }

    /// Total annotations on the books `BookRepository.deleteBooksInFolder`
    /// would delete (same path match) — shown before removing a folder.
    func annotationCount(inFolder folderPath: String) throws -> Int {
        let normalized = folderPath.hasSuffix("/") ? folderPath : folderPath + "/"
        return try dbPool.read { db in
            try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM annotation
                    JOIN book ON book.id = annotation.bookId
                    WHERE book.filePath LIKE ?
                    """,
                arguments: ["\(normalized)%"]
            ) ?? 0
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
