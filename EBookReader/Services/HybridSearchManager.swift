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

    /// Result of a hybrid search. In cookbook/chunk mode, multiple results may
    /// come from the same book — each represents a distinct chunk.
    struct HybridSearchResult: Identifiable, Sendable {
        let id: UUID
        let bookId: UUID
        let title: String
        let author: String?
        let format: BookFormat
        /// Short snippet (~200 chars) suitable for UI cards.
        let snippet: String
        /// Full chunk text, with optional adjacent-chunk context appended,
        /// suitable for feeding into the LLM prompt. Never truncated.
        let fullText: String
        let score: Double
        let chunkId: Int64?
        let chunkIndex: Int?
        let position: ContentPosition?
        /// True if this chunk was flagged by RecipeDetector as recipe-like.
        let isRecipeHit: Bool
        /// Approximate word count of fullText for diagnostics.
        var wordCount: Int { fullText.split(separator: " ").count }
    }

    /// Search options to differentiate general chat vs cookbook mode behavior.
    struct Options: Sendable {
        /// If true, return chunk-level results (multiple per book allowed) and
        /// expand each hit with adjacent chunks for full recipe context.
        var chunkLevel: Bool = false
        /// Number of adjacent chunks to fetch on each side of a hit (cookbook mode).
        var contextWindow: Int = 1
        /// Maximum number of results to return.
        var maxResults: Int = 20
        /// If true, prefer chunks with non-null recipeHint scores.
        var preferRecipeHints: Bool = false

        static let general = Options(chunkLevel: false, contextWindow: 0, maxResults: 20, preferRecipeHints: false)
        static let cookbook = Options(chunkLevel: true, contextWindow: 1, maxResults: 12, preferRecipeHints: true)
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

    /// Convenience: book-level search (general chat). One result per book, snippet preview.
    func search(query: String, books: [Book]) async -> [HybridSearchResult] {
        await search(query: query, books: books, options: .general)
    }

    func search(query: String, books: [Book], options: Options) async -> [HybridSearchResult] {
        let bookMap = Dictionary(uniqueKeysWithValues: books.map { ($0.id, $0) })
        let scopedBookIds = Set(books.map(\.id))

        // Stage 1: FTS5 keyword search (book-level snippets)
        let ftsResults = await ftsManager.search(query: query, books: books)
        let ftsBookIds = Set(ftsResults.map(\.id))
        logger.info("FTS returned \(ftsResults.count) book-level matches across \(ftsBookIds.count) unique books")

        // Stage 2: Vector search across chunks
        var chunkScores: [Int64: (chunk: TextChunk, score: Float, bookId: UUID)] = [:]

        do {
            let queryEmbedding = try await embeddingManager.embedQuery(query)

            // Vector search is scoped to ALL provided books (not just FTS hits) so
            // semantically-relevant chunks aren't missed when keywords don't match.
            let chunkVectors = try await chunkRepository.fetchEmbeddingVectors(forBookIds: scopedBookIds)
            logger.info("Vector pool: \(chunkVectors.count) embedded chunks across \(scopedBookIds.count) books")

            if !chunkVectors.isEmpty {
                // Top-K vector matches
                var scored: [(id: Int64, bookId: UUID, similarity: Float)] = []
                for cv in chunkVectors {
                    let chunkEmbedding = TextChunk.dataToEmbedding(cv.embedding)
                    let sim = LLMEngine.cosineSimilarity(queryEmbedding, chunkEmbedding)
                    scored.append((id: cv.id, bookId: cv.bookId, similarity: sim))
                }
                scored.sort { $0.similarity > $1.similarity }

                let topK = options.chunkLevel ? min(scored.count, options.maxResults * 3) : min(scored.count, 50)
                let topChunkIds = Array(scored.prefix(topK)).map(\.id)

                // Fetch full chunk data
                let fullChunks = try await chunkRepository.fetchChunksByIds(topChunkIds)
                let chunkMap = Dictionary(uniqueKeysWithValues: fullChunks.compactMap { c in c.id.map { ($0, c) } })
                for s in scored.prefix(topK) {
                    if let chunk = chunkMap[s.id] {
                        chunkScores[s.id] = (chunk: chunk, score: s.similarity, bookId: s.bookId)
                    }
                }
            }
        } catch {
            logger.error("Vector search failed: \(error)")
        }

        // Stage 2b: Chunk-level keyword fallback. Vector search misses on
        // short / specific queries ("venison", "bouillabaisse") and skips
        // anything that wasn't embedded. Pull chunks whose text directly
        // contains any of the salient keywords, then merge into chunkScores.
        // Without this, cookbook mode silently returns nothing whenever the
        // recipe term doesn't show up in the embedding's nearest neighbours.
        let keywords = extractKeywords(from: query)
        if !keywords.isEmpty {
            do {
                let kwChunks = try await chunkRepository.searchChunksByKeyword(
                    forBookIds: scopedBookIds,
                    keywords: keywords,
                    limit: options.maxResults * 4
                )
                logger.info("Keyword chunk fallback: \(kwChunks.count) chunks contain \(keywords)")
                for chunk in kwChunks {
                    guard let id = chunk.id else { continue }
                    if let existing = chunkScores[id] {
                        // Already scored by vector — boost it, don't overwrite.
                        chunkScores[id] = (
                            chunk: existing.chunk,
                            score: existing.score + 0.25,
                            bookId: existing.bookId
                        )
                    } else {
                        // New candidate from keyword match — give it a baseline
                        // score that ranks below strong vector hits but above
                        // weak ones.
                        chunkScores[id] = (chunk: chunk, score: 0.45, bookId: chunk.bookId)
                    }
                }
            } catch {
                logger.error("Keyword chunk fallback failed: \(error)")
            }
        }

        // Stage 3: Optional recipe-hint boosting
        var recipeHintIds: Set<Int64> = []
        if options.preferRecipeHints && !chunkScores.isEmpty {
            let chunkIds = Array(chunkScores.keys)
            do {
                recipeHintIds = try await dbPool.read { db -> Set<Int64> in
                    let placeholders = chunkIds.map { _ in "?" }.joined(separator: ",")
                    let sql = "SELECT chunkId FROM recipeHint WHERE chunkId IN (\(placeholders)) AND score >= 0.4"
                    let arguments = StatementArguments(chunkIds.map { Int64($0) })
                    let rows = try Row.fetchAll(db, sql: sql, arguments: arguments)
                    return Set(rows.compactMap { $0["chunkId"] as Int64? })
                }
                logger.info("Recipe hints found for \(recipeHintIds.count) of \(chunkIds.count) chunks")
            } catch {
                logger.error("Recipe hint lookup failed: \(error)")
            }
        }

        // Stage 4: Build results
        if options.chunkLevel {
            let chunkResults = await buildChunkLevelResults(
                chunkScores: chunkScores,
                ftsResults: ftsResults,
                bookMap: bookMap,
                recipeHintIds: recipeHintIds,
                options: options
            )

            // Stage 5 (cookbook fallback): if textChunk-derived results are
            // empty but FTS5 has hits, the AI index hasn't run yet (or
            // extraction silently failed). Build chunks straight from
            // ftsContent so the user gets the venison recipe back instead
            // of "no matches". This is the difference between "search
            // works" and "search shrugs because the embedding pipeline
            // hasn't caught up".
            if chunkResults.isEmpty && !ftsBookIds.isEmpty {
                let ftsChunks = await ftsManager.searchChunks(
                    query: query,
                    scopedBookIds: scopedBookIds,
                    limit: options.maxResults * 2 // overfetch — we filter
                )
                // Apply the same recipe-quality filter we use for vector
                // results, otherwise FTS hits on "chocolate" in a preface
                // would surface as recipes.
                let filteredFTS = ftsChunks.filter { hit in
                    !RecipeDetector.isLikelyNonRecipePage(hit.text)
                        && RecipeDetector.score(hit.text) >= 0.15
                }
                if !filteredFTS.isEmpty {
                    logger.info("FTS chunk fallback: \(filteredFTS.count) of \(ftsChunks.count) hits passed recipe filter (AI index empty)")
                    return filteredFTS.prefix(options.maxResults).compactMap { hit -> HybridSearchResult? in
                        guard let book = bookMap[hit.bookId] else { return nil }
                        return HybridSearchResult(
                            id: UUID(),
                            bookId: hit.bookId,
                            title: book.displayTitle,
                            author: book.author,
                            format: book.format,
                            snippet: String(hit.text.prefix(200)),
                            fullText: hit.text,
                            // FTS5 rank is negative; flip and clamp so it
                            // stacks below real vector hits.
                            score: max(0.3, min(0.6, -hit.rank / 10.0)),
                            chunkId: nil, // no textChunk row to point at
                            chunkIndex: hit.chunkIndex,
                            position: nil,
                            isRecipeHit: false
                        )
                    }
                } else if !ftsChunks.isEmpty {
                    logger.info("FTS chunk fallback: all \(ftsChunks.count) hits were front-matter / non-recipe; returning empty")
                }
            }

            return chunkResults
        } else {
            return buildBookLevelResults(
                chunkScores: chunkScores,
                ftsResults: ftsResults,
                bookMap: bookMap,
                options: options
            )
        }
    }

    // MARK: - Chunk-level (cookbook) result assembly

    private func buildChunkLevelResults(
        chunkScores: [Int64: (chunk: TextChunk, score: Float, bookId: UUID)],
        ftsResults: [FullTextSearchManager.SearchResult],
        bookMap: [UUID: Book],
        recipeHintIds: Set<Int64>,
        options: Options
    ) async -> [HybridSearchResult] {
        // FTS rank lookup for blending
        let ftsRankByBook: [UUID: Double] = Dictionary(uniqueKeysWithValues:
            ftsResults.map { ($0.id, -$0.rank) })
        let ftsValues = Array(ftsRankByBook.values)
        let ftsMax = ftsValues.max() ?? 1.0
        let ftsMin = ftsValues.min() ?? 0.0
        let ftsRange = max(ftsMax - ftsMin, 0.001)

        // Build candidate list, score-blended, with recipe-hint boost.
        // Cookbook mode also runs each chunk through a recipe-quality
        // filter — the keyword/vector path has no notion of "is this
        // actually a recipe?" so a TOC line mentioning chocolate would
        // otherwise come back as a recipe card.
        var candidates: [(chunkId: Int64, chunk: TextChunk, score: Double)] = []
        var rejectedNonRecipe = 0
        var rejectedFrontMatter = 0
        for (chunkId, info) in chunkScores {
            // Recipe-hint chunks pass automatically — they're already
            // confirmed by RecipeDetector at index time. Everything else
            // must clear the live filter.
            if !recipeHintIds.contains(chunkId) {
                if RecipeDetector.isLikelyNonRecipePage(info.chunk.text) {
                    rejectedFrontMatter += 1
                    continue
                }
                let liveScore = RecipeDetector.score(info.chunk.text)
                if liveScore < 0.15 {
                    rejectedNonRecipe += 1
                    continue
                }
            }
            let normalizedFTS = ((ftsRankByBook[info.bookId] ?? 0.0) - ftsMin) / ftsRange
            var blended = ftsWeight * normalizedFTS + (1 - ftsWeight) * Double(info.score)
            if recipeHintIds.contains(chunkId) {
                blended += 0.15 // boost recipe-flagged chunks
            }
            candidates.append((chunkId: chunkId, chunk: info.chunk, score: blended))
        }
        candidates.sort { $0.score > $1.score }
        if rejectedNonRecipe > 0 || rejectedFrontMatter > 0 {
            logger.info("Cookbook filter: rejected \(rejectedFrontMatter) front-matter chunks + \(rejectedNonRecipe) low-recipe-score chunks")
        }

        // Take top N, expand each with adjacent chunks for full recipe context
        let top = Array(candidates.prefix(options.maxResults))
        var seenChunkIds = Set<Int64>()
        var results: [HybridSearchResult] = []

        for cand in top {
            guard !seenChunkIds.contains(cand.chunkId) else { continue }
            seenChunkIds.insert(cand.chunkId)

            // Fetch adjacent chunks for full recipe context
            let expanded: [TextChunk]
            if options.contextWindow > 0 {
                expanded = (try? await chunkRepository.fetchChunksAround(
                    bookId: cand.chunk.bookId,
                    chunkIndex: cand.chunk.chunkIndex,
                    window: options.contextWindow
                )) ?? [cand.chunk]
                // Mark adjacent chunks as seen so we don't dup-emit them
                for c in expanded {
                    if let cid = c.id {
                        seenChunkIds.insert(cid)
                    }
                }
            } else {
                expanded = [cand.chunk]
            }

            // Assemble full text from expanded window
            let fullText = expanded
                .sorted { $0.chunkIndex < $1.chunkIndex }
                .map(\.text)
                .joined(separator: "\n\n")

            guard let book = bookMap[cand.chunk.bookId] else { continue }

            results.append(HybridSearchResult(
                id: UUID(),
                bookId: cand.chunk.bookId,
                title: book.displayTitle,
                author: book.author,
                format: book.format,
                snippet: String(cand.chunk.text.prefix(200)),
                fullText: fullText,
                score: cand.score,
                chunkId: cand.chunkId,
                chunkIndex: cand.chunk.chunkIndex,
                position: cand.chunk.position,
                isRecipeHit: recipeHintIds.contains(cand.chunkId)
            ))
        }

        logger.info("Chunk-level results: \(results.count) chunks, \(results.filter(\.isRecipeHit).count) recipe-hinted, total \(results.reduce(0) { $0 + $1.wordCount }) words")
        return results
    }

    // MARK: - Book-level (general chat) result assembly

    private func buildBookLevelResults(
        chunkScores: [Int64: (chunk: TextChunk, score: Float, bookId: UUID)],
        ftsResults: [FullTextSearchManager.SearchResult],
        bookMap: [UUID: Book],
        options: Options
    ) -> [HybridSearchResult] {
        // Collapse to best chunk per book
        var bestPerBook: [UUID: (chunkId: Int64, chunk: TextChunk, score: Float)] = [:]
        for (chunkId, info) in chunkScores {
            if let existing = bestPerBook[info.bookId] {
                if info.score > existing.score {
                    bestPerBook[info.bookId] = (chunkId, info.chunk, info.score)
                }
            } else {
                bestPerBook[info.bookId] = (chunkId, info.chunk, info.score)
            }
        }

        // Normalize FTS scores
        let ftsScores = ftsResults.map { -$0.rank }
        let ftsMax = ftsScores.max() ?? 1.0
        let ftsMin = ftsScores.min() ?? 0.0
        let ftsRange = max(ftsMax - ftsMin, 0.001)

        var resultMap: [UUID: HybridSearchResult] = [:]

        // Add FTS results (with vector boost if available)
        for (i, fts) in ftsResults.enumerated() {
            let normalizedFTS = (ftsScores[i] - ftsMin) / ftsRange
            let vectorInfo = bestPerBook[fts.id]
            let vectorScore = vectorInfo.map { Double($0.score) } ?? 0.0
            let blended = ftsWeight * normalizedFTS + (1 - ftsWeight) * vectorScore

            let snippet = vectorInfo.map { String($0.chunk.text.prefix(200)) } ?? fts.snippet
            let fullText = vectorInfo?.chunk.text ?? fts.snippet

            resultMap[fts.id] = HybridSearchResult(
                id: UUID(),
                bookId: fts.id,
                title: fts.title,
                author: fts.author,
                format: fts.format,
                snippet: snippet,
                fullText: fullText,
                score: blended,
                chunkId: vectorInfo?.chunkId,
                chunkIndex: vectorInfo?.chunk.chunkIndex,
                position: vectorInfo?.chunk.position,
                isRecipeHit: false
            )
        }

        // Add vector-only results
        for (bookId, info) in bestPerBook where resultMap[bookId] == nil {
            guard let book = bookMap[bookId] else { continue }
            let blended = (1 - ftsWeight) * Double(info.score)
            resultMap[bookId] = HybridSearchResult(
                id: UUID(),
                bookId: bookId,
                title: book.displayTitle,
                author: book.author,
                format: book.format,
                snippet: String(info.chunk.text.prefix(200)),
                fullText: info.chunk.text,
                score: blended,
                chunkId: info.chunkId,
                chunkIndex: info.chunk.chunkIndex,
                position: info.chunk.position,
                isRecipeHit: false
            )
        }

        return resultMap.values.sorted { $0.score > $1.score }
    }

    // MARK: - Keyword extraction

    /// Strips conversational filler ("find me a", "what's a recipe for") and
    /// returns the salient nouns that the keyword fallback should match.
    /// Mirrors FullTextSearchManager's stop list with a few extras specific
    /// to recipe queries.
    private static let stopWords: Set<String> = [
        // generic conversational
        "find", "me", "a", "an", "the", "is", "are", "was", "were", "be",
        "and", "or", "not", "for", "with", "from", "to", "in", "on", "at", "of",
        "i", "my", "we", "you", "it", "its", "this", "that", "some", "any", "all",
        "want", "need", "give", "show", "get", "make", "have", "has", "do", "does",
        "can", "could", "would", "should", "will", "about", "what", "how", "which",
        "like", "please", "just", "very", "really", "also", "so", "but", "if", "then",
        // recipe-specific filler
        "recipe", "recipes", "cook", "cooking", "dish", "meal", "food",
        "tell", "list", "any", "some"
    ]

    private func extractKeywords(from query: String) -> [String] {
        query
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 }
            .filter { !Self.stopWords.contains($0) }
            .filter { !$0.allSatisfy(\.isNumber) }
    }
}
