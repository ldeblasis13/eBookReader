import Foundation
import GRDB
import os

/// Manages FTS5 indexing and search queries.
actor FullTextSearchManager {
    let dbPool: DatabasePool
    private let textExtractor = TextExtractor()
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "EBookReader",
        category: "FTS"
    )

    init(dbPool: DatabasePool) {
        self.dbPool = dbPool
    }

    // MARK: - Search Result

    struct SearchResult: Identifiable, Sendable {
        let id: UUID // book ID
        let title: String
        let author: String?
        let format: BookFormat
        let snippet: String
        let rank: Double
    }

    /// Chunk-level FTS hit. Used by cookbook search as a fallback when the
    /// textChunk / embedding pool is empty (e.g. embedding pipeline didn't
    /// run yet, or extraction silently produced zero chunks). The text is
    /// the full FTS chunk (~5000 chars from TextExtractor), not a snippet.
    struct ChunkHit: Sendable {
        let bookId: UUID
        let chunkIndex: Int
        let text: String
        let rank: Double
    }

    // MARK: - Indexing

    /// Indexes a single book. Call after import.
    func indexBook(_ book: Book) async {
        let chunks = await textExtractor.extractChunks(from: book)
        guard !chunks.isEmpty else { return }

        do {
            try await dbPool.write { db in
                // Remove old entries
                try db.execute(
                    sql: "DELETE FROM ftsContent WHERE bookId = ?",
                    arguments: [book.id.uuidString]
                )

                for (index, chunk) in chunks.enumerated() {
                    try db.execute(
                        sql: "INSERT INTO ftsContent(text, bookId, chunkIndex) VALUES (?, ?, ?)",
                        arguments: [chunk, book.id.uuidString, index]
                    )
                }

                // Mark book as indexed. MUST use GRDB QueryInterface (or
                // typed UUID binding) — book.id is stored as a 16-byte BLOB,
                // so a raw `.uuidString` arg never matches the WHERE clause
                // and the flag stays 0 forever (causing every startup to
                // re-index the same book).
                _ = try Book
                    .filter(Book.Columns.id == book.id)
                    .updateAll(db, Book.Columns.fullTextIndexed.set(to: true))
            }
            logger.info("Indexed \(chunks.count) chunks for \(book.displayTitle)")
        } catch {
            logger.error("Failed to index \(book.displayTitle): \(error)")
        }
    }

    /// Indexes all un-indexed books. Returns the count of newly indexed books.
    @discardableResult
    func indexUnindexedBooks(
        from dbPool: DatabasePool,
        onProgress: @Sendable @escaping (Int, Int) -> Void
    ) async -> Int {
        let unindexed: [Book]
        do {
            unindexed = try await dbPool.read { db in
                try Book.filter(Book.Columns.fullTextIndexed == false).fetchAll(db)
            }
        } catch {
            return 0
        }

        guard !unindexed.isEmpty else { return 0 }

        let total = unindexed.count
        var indexed = 0

        // Process in batches of 4 concurrently
        await withTaskGroup(of: Void.self) { group in
            var pending = unindexed.makeIterator()
            let concurrency = 4

            for _ in 0..<concurrency {
                guard let book = pending.next() else { break }
                group.addTask { await self.indexBook(book) }
            }

            for await _ in group {
                indexed += 1
                onProgress(indexed, total)
                if let book = pending.next() {
                    group.addTask { await self.indexBook(book) }
                }
            }
        }

        logger.info("Background indexing complete: \(indexed)/\(total) books")
        return indexed
    }

    /// Removes FTS entries for a book.
    func removeIndex(for bookId: UUID) async {
        try? await dbPool.write { db in
            try db.execute(
                sql: "DELETE FROM ftsContent WHERE bookId = ?",
                arguments: [bookId.uuidString]
            )
        }
    }

    // MARK: - Search

    /// Three-tier search: filename > metadata > FTS content.
    func search(query: String, books: [Book]) async -> [SearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let queryLower = trimmed.lowercased()

        // Build O(1) lookup once — critical for 100k-book libraries.
        let bookByID: [UUID: Book] = Dictionary(uniqueKeysWithValues: books.map { ($0.id, $0) })

        // Tier 1: Filename matches (highest rank)
        var results: [UUID: SearchResult] = [:]
        for book in books {
            if book.fileName.lowercased().contains(queryLower) {
                results[book.id] = SearchResult(
                    id: book.id,
                    title: book.displayTitle,
                    author: book.author,
                    format: book.format,
                    snippet: "Filename: \(book.fileName)",
                    rank: 100
                )
            }
        }

        // Tier 2: Metadata matches (title/author)
        for book in books where results[book.id] == nil {
            if book.title?.lowercased().contains(queryLower) == true {
                results[book.id] = SearchResult(
                    id: book.id,
                    title: book.displayTitle,
                    author: book.author,
                    format: book.format,
                    snippet: "Title match",
                    rank: 50
                )
            } else if book.author?.lowercased().contains(queryLower) == true {
                results[book.id] = SearchResult(
                    id: book.id,
                    title: book.displayTitle,
                    author: book.author,
                    format: book.format,
                    snippet: "Author: \(book.author ?? "")",
                    rank: 40
                )
            }
        }

        // Tier 3: FTS content matches
        let ftsQuery = buildFTSQuery(trimmed)
        do {
            let ftsResults = try await dbPool.read { db -> [(bookId: String, snippet: String, rank: Double)] in
                let rows = try Row.fetchAll(db, sql: """
                    SELECT bookId, snippet(ftsContent, 0, '**', '**', '...', 40) as snip, rank
                    FROM ftsContent
                    WHERE ftsContent MATCH ?
                    ORDER BY rank
                    LIMIT 200
                """, arguments: [ftsQuery])

                return rows.map { row in
                    (
                        bookId: row["bookId"] as String,
                        snippet: row["snip"] as String,
                        rank: row["rank"] as Double
                    )
                }
            }

            // De-duplicate by bookId using the O(1) dictionary — no linear scan.
            var seenBooks: Set<String> = Set(results.keys.map(\.uuidString))
            for fts in ftsResults {
                guard !seenBooks.contains(fts.bookId),
                      let bookId = UUID(uuidString: fts.bookId),
                      let book = bookByID[bookId] else { continue }
                seenBooks.insert(fts.bookId)

                results[bookId] = SearchResult(
                    id: bookId,
                    title: book.displayTitle,
                    author: book.author,
                    format: book.format,
                    snippet: fts.snippet,
                    rank: fts.rank  // FTS5 rank is negative (closer to 0 = better)
                )
            }
        } catch {
            logger.error("FTS search failed: \(error)")
        }

        return results.values.sorted { $0.rank > $1.rank }
    }

    /// Chunk-level FTS search. Returns the actual matching ftsContent rows
    /// (text + bookId + chunkIndex + rank), bounded to the supplied book set.
    /// Used as the cookbook-mode fallback when the embedded textChunk pool
    /// is empty — the venison recipe is still findable via FTS even when
    /// embeddings haven't been computed.
    func searchChunks(query: String, scopedBookIds: Set<UUID>, limit: Int = 50) async -> [ChunkHit] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !scopedBookIds.isEmpty else { return [] }
        let ftsQuery = buildFTSQuery(trimmed)
        let scopedStrings = Set(scopedBookIds.map(\.uuidString))

        do {
            return try await dbPool.read { db -> [ChunkHit] in
                let rows = try Row.fetchAll(db, sql: """
                    SELECT bookId, chunkIndex, text, rank
                    FROM ftsContent
                    WHERE ftsContent MATCH ?
                    ORDER BY rank
                    LIMIT ?
                """, arguments: [ftsQuery, limit * 4])

                var hits: [ChunkHit] = []
                hits.reserveCapacity(min(rows.count, limit))
                for row in rows {
                    // FTS5 stores bookId as text (TextExtractor wrote it as
                    // .uuidString). Filter to scope client-side so we keep
                    // the GRDB binding sane and avoid re-encoding UUIDs into
                    // the SQL string.
                    let bookIdStr = row["bookId"] as String
                    guard scopedStrings.contains(bookIdStr),
                          let bookUUID = UUID(uuidString: bookIdStr) else { continue }
                    hits.append(ChunkHit(
                        bookId: bookUUID,
                        chunkIndex: row["chunkIndex"] as Int,
                        text: row["text"] as String,
                        rank: row["rank"] as Double
                    ))
                    if hits.count >= limit { break }
                }
                return hits
            }
        } catch {
            logger.error("Chunk FTS search failed: \(error)")
            return []
        }
    }

    private static let stopWords: Set<String> = [
        "find", "me", "the", "a", "an", "is", "are", "was", "were", "be", "been",
        "and", "or", "not", "for", "with", "from", "to", "in", "on", "at", "of",
        "i", "my", "we", "you", "it", "its", "this", "that", "some", "any", "all",
        "want", "need", "give", "show", "get", "make", "have", "has", "do", "does",
        "can", "could", "would", "should", "will", "about", "what", "how", "which",
        "like", "please", "just", "very", "really", "also", "so", "but", "if", "then"
    ]

    private func buildFTSQuery(_ input: String) -> String {
        let words = input.components(separatedBy: .whitespacesAndNewlines)
            .map { $0.lowercased() }
            .filter { !$0.isEmpty && !Self.stopWords.contains($0) }
            .filter { $0.count > 1 } // skip single characters and numbers
            .filter { !$0.allSatisfy(\.isNumber) } // skip pure numbers like "5", "10"
            .map { word -> String in
                let escaped = word.replacingOccurrences(of: "\"", with: "\"\"")
                return "\(escaped)*"
            }

        guard !words.isEmpty else { return input }

        // Use OR so any matching word returns results (more recall)
        return words.joined(separator: " OR ")
    }
}
