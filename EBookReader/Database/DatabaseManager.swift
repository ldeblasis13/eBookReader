import Foundation
import GRDB
import os

final class DatabaseManager: Sendable {
    static let shared = DatabaseManager()

    let dbPool: DatabasePool

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "EBookReader",
        category: "Database"
    )

    private init() {
        do {
            let appSupportURL = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            ).appendingPathComponent("EBookReader", isDirectory: true)

            try FileManager.default.createDirectory(
                at: appSupportURL,
                withIntermediateDirectories: true
            )

            let dbPath = appSupportURL.appendingPathComponent("library.sqlite").path
            let config = Configuration()
            dbPool = try DatabasePool(path: dbPath, configuration: config)
            try migrator.migrate(dbPool)
            Self.logger.info("Database initialized at \(dbPath)")
        } catch {
            fatalError("Database initialization failed: \(error)")
        }
    }

    private var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        #if DEBUG
        migrator.eraseDatabaseOnSchemaChange = true
        #endif

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
                t.column("coverImageData", .blob)
                t.column("bookmarkData", .blob)
                t.column("dateAdded", .datetime).notNull()
                t.column("dateLastOpened", .datetime)
                t.column("lastReadPosition", .text)
                t.column("fullTextIndexed", .boolean).notNull().defaults(to: false)
            }

            try db.create(index: "idx_book_format", on: "book", columns: ["format"])
            try db.create(index: "idx_book_title", on: "book", columns: ["title"])
            try db.create(index: "idx_book_author", on: "book", columns: ["author"])
            try db.create(index: "idx_book_dateAdded", on: "book", columns: ["dateAdded"])

            try db.create(table: "watchedFolder") { t in
                t.primaryKey("id", .text).notNull()
                t.column("path", .text).notNull().unique()
                t.column("bookmarkData", .blob).notNull()
                t.column("dateAdded", .datetime).notNull()
                t.column("isFullImport", .boolean).notNull().defaults(to: true)
            }
        }

        migrator.registerMigration("v2") { db in
            try db.create(table: "collectionGroup") { t in
                t.primaryKey("id", .text).notNull()
                t.column("name", .text).notNull()
                t.column("sortOrder", .integer).notNull().defaults(to: 0)
                t.column("dateCreated", .datetime).notNull()
            }

            try db.create(table: "collection") { t in
                t.primaryKey("id", .text).notNull()
                t.column("name", .text).notNull()
                t.column("collectionGroupId", .text)
                    .references("collectionGroup", onDelete: .setNull)
                t.column("sortOrder", .integer).notNull().defaults(to: 0)
                t.column("dateCreated", .datetime).notNull()
            }

            try db.create(table: "bookCollection") { t in
                t.column("bookId", .text).notNull()
                    .references("book", onDelete: .cascade)
                t.column("collectionId", .text).notNull()
                    .references("collection", onDelete: .cascade)
                t.column("dateAdded", .datetime).notNull()
                t.primaryKey(["bookId", "collectionId"])
            }

            try db.create(
                index: "idx_bookCollection_collectionId",
                on: "bookCollection",
                columns: ["collectionId"]
            )
        }

        migrator.registerMigration("v3") { db in
            // FTS5 virtual table for full-text search of book content
            try db.execute(sql: """
                CREATE VIRTUAL TABLE ftsContent USING fts5(
                    text,
                    bookId UNINDEXED,
                    chunkIndex UNINDEXED,
                    tokenize='porter unicode61'
                )
            """)
        }

        migrator.registerMigration("v4") { db in
            try db.create(table: "annotation") { t in
                t.primaryKey("id", .text).notNull()
                t.column("bookId", .text).notNull()
                    .references("book", onDelete: .cascade)
                t.column("tool", .text).notNull()
                t.column("color", .text).notNull()
                t.column("position", .text).notNull()
                t.column("selectedText", .text)
                t.column("note", .text)
                t.column("data", .text)
                t.column("dateCreated", .datetime).notNull()
                t.column("dateModified", .datetime).notNull()
            }

            try db.create(index: "idx_annotation_bookId", on: "annotation", columns: ["bookId"])
            try db.create(
                index: "idx_annotation_bookId_dateCreated",
                on: "annotation",
                columns: ["bookId", "dateCreated"]
            )
        }

        migrator.registerMigration("v5") { db in
            // Drop the large coverImageData BLOB — thumbnails are now stored as files in
            // ~/Library/Caches/EBookReader/Thumbnails/{uuid}.jpg.
            // SQLite 3.35+ (macOS 12+) supports ALTER TABLE … DROP COLUMN.
            try db.execute(sql: "ALTER TABLE book DROP COLUMN coverImageData")

            // Add a lightweight flag so the grid can decide whether to attempt a disk-cache
            // lookup before showing the placeholder.
            try db.alter(table: "book") { t in
                t.add(column: "hasCachedThumbnail", .boolean).notNull().defaults(to: false)
            }
        }

        return migrator
    }
}
