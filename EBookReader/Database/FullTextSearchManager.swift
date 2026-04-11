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

                // Mark book as indexed
                try db.execute(
                    sql: "UPDATE book SET fullTextIndexed = 1 WHERE id = ?",
                    arguments: [book.id.uuidString]
                )
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

    private func buildFTSQuery(_ input: String) -> String {
        // Split into words and join with implicit AND
        let words = input.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .map { word -> String in
                let escaped = word.replacingOccurrences(of: "\"", with: "\"\"")
                return escaped.contains(" ") ? "\"\(escaped)\"" : "\(escaped)*"
            }
        return words.joined(separator: " ")
    }
}
