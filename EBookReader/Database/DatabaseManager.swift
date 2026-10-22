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

    /// The user's real library. Only Release builds may open it.
    static let productionDatabaseFileName = "library.sqlite"
    /// Scratch library for Debug builds run from Xcode, so an older or edited
    /// build can never migrate (or erase) the real library.
    static let debugDatabaseFileName = "library-debug.sqlite"

    static var databaseFileName: String {
        #if DEBUG
        debugDatabaseFileName
        #else
        productionDatabaseFileName
        #endif
    }

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

            let fileName = Self.databaseFileName
            let dbPath = appSupportURL.appendingPathComponent(fileName).path
            let config = Configuration()
            dbPool = try DatabasePool(path: dbPath, configuration: config)

            // Wiping on schema change is a Debug convenience, and it is only
            // allowed on the scratch file — never on the real library.
            var migrator = Self.makeMigrator()
            migrator.eraseDatabaseOnSchemaChange = (fileName == Self.debugDatabaseFileName)
            try migrator.migrate(dbPool)
            Self.logger.info("Database initialized at \(dbPath)")
        } catch {
            fatalError("Database initialization failed: \(error)")
        }
    }

    /// The app's schema. Internal so tests can migrate a scratch database
    /// with the real schema instead of a hand-copied one.
    static func makeMigrator() -> DatabaseMigrator {
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

        migrator.registerMigration("v6") { db in
            // Text chunks with embedding vectors for semantic search
            try db.create(table: "textChunk") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("bookId", .text).notNull()
                    .references("book", onDelete: .cascade)
                t.column("chunkIndex", .integer).notNull()
                t.column("text", .text).notNull()
                t.column("positionJSON", .text)
                t.column("embedding", .blob)
                t.column("dateIndexed", .datetime).notNull()
            }
            try db.create(index: "idx_textChunk_bookId", on: "textChunk", columns: ["bookId"])
            try db.create(
                index: "idx_textChunk_bookId_chunkIndex",
                on: "textChunk",
                columns: ["bookId", "chunkIndex"],
                unique: true
            )

            // Track embedding status per book
            try db.alter(table: "book") { t in
                t.add(column: "embeddingIndexed", .boolean).notNull().defaults(to: false)
            }

            // Model download/status tracking
            try db.create(table: "modelInfo") { t in
                t.primaryKey("id", .text).notNull()
                t.column("displayName", .text).notNull()
                t.column("fileName", .text).notNull()
                t.column("expectedSizeBytes", .integer).notNull()
                t.column("sha256", .text)
                t.column("downloadURL", .text).notNull()
                t.column("localPath", .text)
                t.column("status", .text).notNull()
                t.column("downloadedBytes", .integer).notNull().defaults(to: 0)
                t.column("dateDownloaded", .datetime)
            }
        }

        migrator.registerMigration("v7") { db in
            // Cookbook mode: collection type flag
            try db.alter(table: "collection") { t in
                t.add(column: "collectionType", .text).notNull().defaults(to: "default")
            }

            // Recipe hints from heuristic detection
            try db.create(table: "recipeHint") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("chunkId", .integer).notNull()
                    .references("textChunk", onDelete: .cascade)
                t.column("score", .double).notNull()
                t.column("detectedTitle", .text)
                t.column("dateDetected", .datetime).notNull()
            }
            try db.create(index: "idx_recipeHint_chunkId", on: "recipeHint", columns: ["chunkId"], unique: true)
            try db.create(index: "idx_recipeHint_score", on: "recipeHint", columns: ["score"])
        }

        migrator.registerMigration("v8_pooledEmbeddings") { db in
            try DatabaseManager.clearEmbeddingsForRebuild(db)
        }

        // Book files the user deleted from the library, so reconciling a
        // watched folder doesn't import them again.
        migrator.registerMigration("v9_excludedBookFile") { db in
            try db.create(table: "excludedBookFile") { t in
                t.primaryKey("path", .text).notNull()
                t.column("fileSize", .integer).notNull()
                t.column("dateExcluded", .datetime).notNull()
            }
            try db.create(index: "idx_excludedBookFile_fileSize", on: "excludedBookFile", columns: ["fileSize"])
        }

        return migrator
    }

    /// Stored vectors were read from llama.cpp's raw per-token output;
    /// LLMEngine.embed now returns pooled sentence embeddings, and the two
    /// aren't comparable. Clears the old vectors and flags so startup
    /// embedding indexing rebuilds them. Chunk rows stay (with their recipe
    /// hints) — EmbeddingManager re-embeds them in place.
    static func clearEmbeddingsForRebuild(_ db: Database) throws {
        try db.execute(sql: "UPDATE textChunk SET embedding = NULL WHERE embedding IS NOT NULL")
        try db.execute(sql: "UPDATE book SET embeddingIndexed = 0 WHERE embeddingIndexed = 1")
    }
}
