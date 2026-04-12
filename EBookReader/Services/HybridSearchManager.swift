import Foundation
import GRDB
import os

/// Combines FTS5 keyword search with vector embedding similarity for semantic search.
/// Pipeline: FTS5 pre-filter → embed query → vector rerank → blended scores.
actor HybridSearchManager {
    private let dbPool: DatabasePool
    private let ftsManager: FullTextSearchManager
    private let embeddingManager: EmbeddingManager
    private let chunkRepository: TextChunkRepository
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "EBookReader",
        category: "HybridSearchManager"
    )

    /// Weight for FTS5 score vs vector similarity (0 = pure vector, 1 = pure FTS5).
    private let ftsWeight: Double = 0.4

    struct HybridSearchResult: Identifiable, Sendable {
        let id: UUID
        let bookId: UUID
        let title: String
        let author: String?
        let format: BookFormat
        let snippet: String
        let score: Double
        let chunkId: Int64?
        let position: ContentPosition?
    }

    init(
        dbPool: DatabasePool,
        ftsManager: FullTextSearchManager,
        embeddingManager: EmbeddingManager,
        chunkRepository: TextChunkRepository
    ) {
        self.dbPool = dbPool
        self.ftsManager = ftsManager
        self.embeddingManager = embeddingManager
        self.chunkRepository = chunkRepository
    }

    // MARK: - Hybrid Search

    func search(query: String, books: [Book]) async -> [HybridSearchResult] {
        // Stage 1: FTS5 keyword search
        let ftsResults = await ftsManager.search(query: query, books: books)
        let ftsBookIds = Set(ftsResults.map(\.id))

        // Stage 2: Embed query and compute vector similarity
        var vectorScores: [UUID: (score: Float, chunkId: Int64, text: String, position: ContentPosition?)] = [:]

        do {
            let queryEmbedding = try await embeddingManager.embedQuery(query)

            // Load embeddings for FTS-matched books (or all books if FTS returned nothing)
            let targetBookIds = ftsBookIds.isEmpty ? Set(books.map(\.id)) : ftsBookIds
            let chunkVectors = try await chunkRepository.fetchEmbeddingVectors(forBookIds: targetBookIds)

            guard !chunkVectors.isEmpty else {
                // No embeddings available — return FTS-only results
                return ftsResults.map { fts in
                    HybridSearchResult(
                        id: UUID(),
                        bookId: fts.id,
                        title: fts.title,
                        author: fts.author,
                        format: fts.format,
                        snippet: fts.snippet,
                        score: Double(-fts.rank), // FTS5 rank is negative; closer to 0 = better
                        chunkId: nil,
                        position: nil
                    )
                }
            }

            // Compute cosine similarity for each chunk
            for cv in chunkVectors {
                let chunkEmbedding = TextChunk.dataToEmbedding(cv.embedding)
                let similarity = LLMEngine.cosineSimilarity(queryEmbedding, chunkEmbedding)

                // Keep the highest-scoring chunk per book
                if let existing = vectorScores[cv.bookId] {
                    if similarity > existing.score {
                        // Fetch the chunk text for snippet
                        vectorScores[cv.bookId] = (
                            score: similarity,
                            chunkId: cv.id,
                            text: "", // will fetch below
                            position: nil
                        )
                    }
                } else {
                    vectorScores[cv.bookId] = (
                        score: similarity,
                        chunkId: cv.id,
                        text: "",
                        position: nil
                    )
                }
            }

            // Fetch full chunk data for top results
            let topChunkIds = vectorScores.values.map(\.chunkId)
            if !topChunkIds.isEmpty {
                let fullChunks = try await chunkRepository.fetchChunksByIds(topChunkIds)
                let chunkMap = Dictionary(uniqueKeysWithValues: fullChunks.compactMap { c in
                    c.id.map { ($0, c) }
                })
                for (bookId, var info) in vectorScores {
                    if let chunk = chunkMap[info.chunkId] {
                        info.text = String(chunk.text.prefix(200))
                        info.position = chunk.position
                        vectorScores[bookId] = info
                    }
                }
            }
        } catch {
            logger.error("Vector search failed: \(error)")
            // Fall through to FTS-only results
        }

        // Stage 3: Blend scores
        let bookMap = Dictionary(uniqueKeysWithValues: books.map { ($0.id, $0) })

        // Normalize FTS scores to [0, 1]
        let ftsScores = ftsResults.map { -$0.rank } // positive values
        let ftsMax = ftsScores.max() ?? 1.0
        let ftsMin = ftsScores.min() ?? 0.0
        let ftsRange = max(ftsMax - ftsMin, 0.001)

        var resultMap: [UUID: HybridSearchResult] = [:]

        // Add FTS results
        for (i, fts) in ftsResults.enumerated() {
            let normalizedFTS = (ftsScores[i] - ftsMin) / ftsRange
            let vectorInfo = vectorScores[fts.id]
            let vectorScore = vectorInfo.map { Double($0.score) } ?? 0.0
            let blended = ftsWeight * normalizedFTS + (1 - ftsWeight) * vectorScore

            resultMap[fts.id] = HybridSearchResult(
                id: UUID(),
                bookId: fts.id,
                title: fts.title,
                author: fts.author,
                format: fts.format,
                snippet: vectorInfo?.text.isEmpty == false ? vectorInfo!.text : fts.snippet,
                score: blended,
                chunkId: vectorInfo?.chunkId,
                position: vectorInfo?.position
            )
        }

        // Add vector-only results (books found by embedding but not FTS)
        for (bookId, info) in vectorScores where resultMap[bookId] == nil {
            guard let book = bookMap[bookId] else { continue }
            let blended = (1 - ftsWeight) * Double(info.score)
            resultMap[bookId] = HybridSearchResult(
                id: UUID(),
                bookId: bookId,
                title: book.displayTitle,
                author: book.author,
                format: book.format,
                snippet: info.text,
                score: blended,
                chunkId: info.chunkId,
                position: info.position
            )
        }

        // Stage 4: Sort by blended score descending
        return resultMap.values.sorted { $0.score > $1.score }
    }
}
