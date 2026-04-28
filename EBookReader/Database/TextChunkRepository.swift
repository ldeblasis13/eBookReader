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

    /// Counts embedded chunks for a set of books (diagnostics).
    func countEmbeddedChunks(forBookIds bookIds: Set<UUID>) throws -> Int {
        guard !bookIds.isEmpty else { return 0 }
        return try dbPool.read { db in
            try TextChunk
                .filter(bookIds.contains(TextChunk.Columns.bookId))
                .filter(TextChunk.Columns.embedding != nil)
                .fetchCount(db)
        }
    }

    /// Counts total chunks for a set of books (diagnostics).
    func countChunks(forBookIds bookIds: Set<UUID>) throws -> Int {
        guard !bookIds.isEmpty else { return 0 }
        return try dbPool.read { db in
            try TextChunk
                .filter(bookIds.contains(TextChunk.Columns.bookId))
                .fetchCount(db)
        }
    }

    /// Fetches a chunk and its adjacent chunks (±window) for full-context recipe assembly.
    func fetchChunksAround(bookId: UUID, chunkIndex: Int, window: Int) throws -> [TextChunk] {
        let lower = max(0, chunkIndex - window)
        let upper = chunkIndex + window
        return try dbPool.read { db in
            try TextChunk
                .filter(TextChunk.Columns.bookId == bookId)
                .filter(TextChunk.Columns.chunkIndex >= lower
                     && TextChunk.Columns.chunkIndex <= upper)
                .order(TextChunk.Columns.chunkIndex)
                .fetchAll(db)
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
    /// Uses GRDB's parameter binding (NOT raw `.uuidString` interpolation) so
    /// UUIDs encode the same way they were stored — otherwise BLOB-encoded
    /// UUIDs in the row never match string literals in the WHERE clause.
    func fetchEmbeddingVectors(forBookIds bookIds: Set<UUID>) throws -> [(id: Int64, bookId: UUID, embedding: Data)] {
        guard !bookIds.isEmpty else { return [] }
        return try dbPool.read { db in
            let chunks = try TextChunk
                .filter(bookIds.contains(TextChunk.Columns.bookId))
                .filter(TextChunk.Columns.embedding != nil)
                .fetchAll(db)
            return chunks.compactMap { chunk in
                guard let id = chunk.id, let embedding = chunk.embedding else { return nil }
                return (id: id, bookId: chunk.bookId, embedding: embedding)
            }
        }
    }

    /// Direct chunk-level keyword search via SQL LIKE. Used as a cookbook-mode
    /// fallback when vector search misses (e.g. short queries like "venison")
    /// or when chunks haven't been embedded yet. Returns chunks whose text
    /// contains ANY of the supplied keywords (case-insensitive).
    func searchChunksByKeyword(
        forBookIds bookIds: Set<UUID>,
        keywords: [String],
        limit: Int = 50
    ) throws -> [TextChunk] {
        guard !bookIds.isEmpty, !keywords.isEmpty else { return [] }
        let cleaned = keywords
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { $0.count >= 2 }
        guard !cleaned.isEmpty else { return [] }

        return try dbPool.read { db in
            // Build OR-of-LIKEs predicate using GRDB QueryInterface so UUID
            // encoding matches what was stored.
            var query = TextChunk.filter(bookIds.contains(TextChunk.Columns.bookId))
            // SQLite LIKE is case-insensitive for ASCII by default.
            let likeClauses = cleaned.map { kw in
                "LOWER(text) LIKE '%\(kw.replacingOccurrences(of: "'", with: "''"))%'"
            }
            query = query.filter(sql: "(" + likeClauses.joined(separator: " OR ") + ")")
            return try query.limit(limit).fetchAll(db)
        }
    }

    // MARK: - Delete

    func deleteChunks(forBook bookId: UUID) throws {
        try dbPool.write { db in
            _ = try TextChunk.filter(TextChunk.Columns.bookId == bookId).deleteAll(db)
        }
    }
}
