import Foundation
import GRDB

/// GRDB repository for text chunks with embeddings.
actor TextChunkRepository {
    let dbPool: DatabasePool

    init(dbPool: DatabasePool) {
        self.dbPool = dbPool
    }

    // MARK: - Insert

    func insertChunks(_ chunks: [TextChunk]) throws {
        try dbPool.write { db in
            for var chunk in chunks {
                try chunk.insert(db)
            }
        }
    }

    // MARK: - Update Embeddings

    func updateEmbeddings(_ updates: [(id: Int64, embedding: Data)]) throws {
        try dbPool.write { db in
            for update in updates {
                try db.execute(
                    sql: "UPDATE textChunk SET embedding = ? WHERE id = ?",
                    arguments: [update.embedding, update.id]
                )
            }
        }
    }

    // MARK: - Fetch

    func fetchChunks(forBook bookId: UUID) throws -> [TextChunk] {
        try dbPool.read { db in
            try TextChunk
                .filter(TextChunk.Columns.bookId == bookId)
                .order(TextChunk.Columns.chunkIndex)
                .fetchAll(db)
        }
    }

    func fetchChunksByIds(_ ids: [Int64]) throws -> [TextChunk] {
        try dbPool.read { db in
            try TextChunk.filter(ids.contains(TextChunk.Columns.id)).fetchAll(db)
        }
    }

    func countUnembeddedChunks() throws -> Int {
        try dbPool.read { db in
            try TextChunk.filter(TextChunk.Columns.embedding == nil).fetchCount(db)
        }
    }

    /// Fetches chunks with embeddings for a set of books (for vector search reranking).
    func fetchEmbeddedChunks(forBookIds bookIds: Set<UUID>, limit: Int = 1000) throws -> [TextChunk] {
        try dbPool.read { db in
            try TextChunk
                .filter(bookIds.contains(TextChunk.Columns.bookId))
                .filter(TextChunk.Columns.embedding != nil)
                .limit(limit)
                .fetchAll(db)
        }
    }

    /// Lightweight fetch of just (id, bookId, embedding) for vector search.
    func fetchEmbeddingVectors(forBookIds bookIds: Set<UUID>) throws -> [(id: Int64, bookId: UUID, embedding: Data)] {
        try dbPool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, bookId, embedding FROM textChunk
                WHERE bookId IN (\(bookIds.map { "'\($0.uuidString)'" }.joined(separator: ",")))
                AND embedding IS NOT NULL
                """)
            return rows.map { row in
                (
                    id: row["id"] as Int64,
                    bookId: UUID(uuidString: row["bookId"] as String)!,
                    embedding: row["embedding"] as Data
                )
            }
        }
    }

    // MARK: - Delete

    func deleteChunks(forBook bookId: UUID) throws {
        try dbPool.write { db in
            _ = try TextChunk.filter(TextChunk.Columns.bookId == bookId).deleteAll(db)
        }
    }
}
