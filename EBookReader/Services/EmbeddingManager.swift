import Foundation
import GRDB
import os

/// Orchestrates the embedding pipeline: extract text → chunk → embed → store.
/// Runs in background with progress reporting. Resumable — chunks with NULL
/// embeddings are picked up on restart.
actor EmbeddingManager {
    private let dbPool: DatabasePool
    private let llmEngine: LLMEngine
    private let textExtractor: PositionAwareTextExtractor
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "EBookReader",
        category: "EmbeddingManager"
    )

    private let batchSize = 32

    init(dbPool: DatabasePool, llmEngine: LLMEngine, textExtractor: PositionAwareTextExtractor) {
        self.dbPool = dbPool
        self.llmEngine = llmEngine
        self.textExtractor = textExtractor
    }

    // MARK: - Index Single Book

    /// Extracts, chunks, embeds, and stores vectors for one book.
    func indexBook(_ book: Book) async {
        let repo = TextChunkRepository(dbPool: dbPool)

        // Skip if already indexed
        guard !book.embeddingIndexed else { return }

        // Extract positioned chunks
        let positionedChunks = await textExtractor.extractPositionedChunks(from: book)
        guard !positionedChunks.isEmpty else {
            logger.info("No text extracted for embedding: \(book.displayTitle)")
            return
        }

        // Store chunks with NULL embeddings first (enables resume)
        let textChunks = positionedChunks.map { pc in
            TextChunk(
                bookId: book.id,
                chunkIndex: pc.chunkIndex,
                text: pc.text,
                positionJSON: pc.position.toJSON(),
                embedding: nil,
                dateIndexed: Date()
            )
        }

        do {
            // Delete any existing chunks for this book (in case of re-index)
            try await repo.deleteChunks(forBook: book.id)
            try await repo.insertChunks(textChunks)
        } catch {
            logger.error("Failed to store chunks for \(book.displayTitle): \(error)")
            return
        }

        // Fetch back the inserted chunks to get their IDs
        let storedChunks: [TextChunk]
        do {
            storedChunks = try await repo.fetchChunks(forBook: book.id)
        } catch {
            logger.error("Failed to fetch stored chunks: \(error)")
            return
        }

        // Generate embeddings in batches
        let chunksNeedingEmbedding = storedChunks.filter { $0.embedding == nil }
        var updates: [(id: Int64, embedding: Data)] = []

        for batchStart in stride(from: 0, to: chunksNeedingEmbedding.count, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, chunksNeedingEmbedding.count)
            let batch = Array(chunksNeedingEmbedding[batchStart..<batchEnd])
            let texts = batch.map(\.text)

            do {
                let embeddings = try await llmEngine.embedBatch(texts: texts)
                for (i, embedding) in embeddings.enumerated() {
                    guard let chunkId = batch[i].id else { continue }
                    updates.append((id: chunkId, embedding: TextChunk.embeddingToData(embedding)))
                }
            } catch {
                logger.error("Embedding batch failed at \(batchStart): \(error)")
                continue
            }
        }

        // Store embeddings
        if !updates.isEmpty {
            do {
                try await repo.updateEmbeddings(updates)
            } catch {
                logger.error("Failed to store embeddings: \(error)")
                return
            }
        }

        // Mark book as embedding-indexed
        do {
            try await dbPool.write { db in
                try db.execute(
                    sql: "UPDATE book SET embeddingIndexed = 1 WHERE id = ?",
                    arguments: [book.id.uuidString]
                )
            }
        } catch {
            logger.error("Failed to mark book as embedding-indexed: \(error)")
        }

        logger.info("Embedded \(updates.count) chunks for: \(book.displayTitle)")
    }

    // MARK: - Batch Index

    /// Indexes all books that haven't been embedding-indexed yet.
    /// Reports progress as (booksCompleted, totalBooks).
    @discardableResult
    func indexUnembeddedBooks(
        from dbPool: DatabasePool,
        onProgress: @Sendable @escaping (Int, Int) -> Void
    ) async -> Int {
        let unindexedBooks: [Book]
        do {
            unindexedBooks = try await dbPool.read { db in
                try Book
                    .filter(Book.Columns.embeddingIndexed == false)
                    .fetchAll(db)
            }
        } catch {
            logger.error("Failed to fetch unindexed books: \(error)")
            return 0
        }

        guard !unindexedBooks.isEmpty else { return 0 }

        let total = unindexedBooks.count
        var completed = 0

        for book in unindexedBooks {
            await indexBook(book)
            completed += 1
            onProgress(completed, total)
        }

        logger.info("Embedding indexing complete: \(completed)/\(total) books")
        return completed
    }

    // MARK: - Cleanup

    func removeIndex(for bookId: UUID) async {
        let repo = TextChunkRepository(dbPool: dbPool)
        try? await repo.deleteChunks(forBook: bookId)
    }

    // MARK: - Query Embedding

    /// Embeds a search query for vector comparison.
    func embedQuery(_ query: String) async throws -> [Float] {
        try await llmEngine.embed(text: query)
    }
}
