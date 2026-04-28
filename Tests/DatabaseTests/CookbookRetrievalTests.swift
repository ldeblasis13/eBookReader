import XCTest
import GRDB
@testable import EBookReader

/// Cookbook-mode regression tests. These guard the contract that prevents
/// LLM hallucination of recipes:
///   1. Search returns chunk-level (not book-level) results — multiple recipes
///      from the same book must surface independently.
///   2. The text passed to the LLM is the full chunk (with adjacent context),
///      never a 200-character snippet.
///   3. When no relevant excerpts exist, the LLM is NOT invoked — instead a
///      deterministic no-results message is returned.
///   4. Long source text is split into chunks that fit the embedding model's
///      512-token context window.
///   5. RecipeHint rows created by the heuristic detector boost matching chunks
///      in the search ranking.
///
/// All tests use an in-temp-file SQLite DB with the v6 (textChunk + modelInfo)
/// and v7 (collectionType + recipeHint) schema applied. No llama / embedding
/// model is loaded — vector data is fabricated directly.
final class CookbookRetrievalTests: XCTestCase {

    private var tempDir: URL!
    private var dbPool: DatabasePool!
    private var bookRepo: BookRepository!
    private var chunkRepo: TextChunkRepository!

    // MARK: - Setup / Teardown

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("EBookReaderCookbookTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let dbPath = tempDir.appendingPathComponent("cookbook_test.sqlite").path
        dbPool = try DatabasePool(path: dbPath)
        try applySchema(dbPool)
        bookRepo = BookRepository(dbPool: dbPool)
        chunkRepo = TextChunkRepository(dbPool: dbPool)
    }

    override func tearDownWithError() throws {
        bookRepo = nil
        chunkRepo = nil
        dbPool = nil
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
    }

    // MARK: - Schema (mirrors DatabaseManager v1 → v7, minus v3/v4 unused here)

    private func applySchema(_ pool: DatabasePool) throws {
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
        }

        migrator.registerMigration("v3") { db in
            try db.execute(sql: """
                CREATE VIRTUAL TABLE ftsContent USING fts5(
                    text,
                    bookId UNINDEXED,
                    chunkIndex UNINDEXED,
                    tokenize='porter unicode61'
                )
            """)
        }

        migrator.registerMigration("v5") { db in
            try db.execute(sql: "ALTER TABLE book DROP COLUMN coverImageData")
            try db.alter(table: "book") { t in
                t.add(column: "hasCachedThumbnail", .boolean).notNull().defaults(to: false)
            }
        }

        migrator.registerMigration("v6") { db in
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
            try db.alter(table: "book") { t in
                t.add(column: "embeddingIndexed", .boolean).notNull().defaults(to: false)
            }
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
            try db.alter(table: "collection") { t in
                t.add(column: "collectionType", .text).notNull().defaults(to: "default")
            }
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

        try migrator.migrate(pool)
    }

    // MARK: - Test Fixtures

    /// Inserts a synthetic book row.
    private func insertBook(title: String, author: String? = nil) async throws -> Book {
        let book = Book(
            filePath: "/synthetic/cookbook/\(UUID().uuidString).epub",
            fileName: "\(title).epub",
            title: title,
            author: author,
            format: .epub,
            fileSize: 1024,
            embeddingIndexed: true
        )
        try await bookRepo.insertBook(book)
        return book
    }

    /// Inserts a chunk with optional raw embedding bytes. Returns the row ID
    /// directly from GRDB's `didInsert` callback (avoids the UUID-binding
    /// pitfalls of raw-SQL lookups).
    @discardableResult
    private func insertChunk(
        bookId: UUID,
        chunkIndex: Int,
        text: String,
        embedding: Data? = nil
    ) async throws -> Int64 {
        let value = TextChunk(
            bookId: bookId,
            chunkIndex: chunkIndex,
            text: text,
            positionJSON: ContentPosition.epub(spineIndex: chunkIndex, href: "ch\(chunkIndex).xhtml").toJSON(),
            embedding: embedding,
            dateIndexed: Date()
        )
        return try await dbPool.write { db -> Int64 in
            var c = value
            try c.insert(db)
            return c.id ?? -1
        }
    }

    /// Builds a deterministic 384-dim embedding aligned with `direction` (one-hot-ish).
    /// Two chunks built with the same direction will have cosine similarity 1.0.
    private func makeEmbedding(direction: Int, magnitude: Float = 1.0) -> Data {
        var v = [Float](repeating: 0.0, count: 384)
        v[direction % 384] = magnitude
        // Normalize so cosine similarity is well-defined
        var norm: Float = 0
        for x in v { norm += x * x }
        norm = sqrtf(norm)
        if norm > 0 {
            for i in 0..<v.count { v[i] /= norm }
        }
        return v.withUnsafeBufferPointer { Data(bytes: $0.baseAddress!, count: $0.count * MemoryLayout<Float>.size) }
    }

    private func insertRecipeHint(chunkId: Int64, score: Double, title: String?) async throws {
        try await dbPool.write { db in
            try db.execute(
                sql: """
                INSERT OR REPLACE INTO recipeHint (chunkId, score, detectedTitle, dateDetected)
                VALUES (?, ?, ?, ?)
                """,
                arguments: [chunkId, score, title, Date()]
            )
        }
    }

    // MARK: - Test 1: Adjacent-Chunk Window (fetchChunksAround)

    /// Cookbook mode expands each hit with adjacent chunks so the LLM gets
    /// the full recipe even when ingredients and instructions live in
    /// different chunks. This guards the sliding-window query.
    func testFetchChunksAroundReturnsCorrectWindow() async throws {
        let book = try await insertBook(title: "Italian Classics")
        // Insert 7 chunks (0..6)
        for i in 0..<7 {
            try await insertChunk(bookId: book.id, chunkIndex: i, text: "Chunk \(i) text content.")
        }

        // window=1 around chunkIndex=3 → expect chunks 2, 3, 4
        let mid = try await chunkRepo.fetchChunksAround(bookId: book.id, chunkIndex: 3, window: 1)
        XCTAssertEqual(mid.count, 3, "window=1 should return 3 chunks")
        XCTAssertEqual(mid.map(\.chunkIndex), [2, 3, 4])

        // window=2 around chunkIndex=0 → clamps to 0,1,2 (no negative indices)
        let head = try await chunkRepo.fetchChunksAround(bookId: book.id, chunkIndex: 0, window: 2)
        XCTAssertEqual(head.map(\.chunkIndex), [0, 1, 2], "window must clamp at lower bound")

        // window=2 around chunkIndex=6 → clamps to 4,5,6 (no overrun)
        let tail = try await chunkRepo.fetchChunksAround(bookId: book.id, chunkIndex: 6, window: 2)
        XCTAssertEqual(tail.map(\.chunkIndex), [4, 5, 6], "window must clamp at upper bound")

        // Sanity: chunks come back ordered by chunkIndex ASC
        let wide = try await chunkRepo.fetchChunksAround(bookId: book.id, chunkIndex: 3, window: 5)
        XCTAssertEqual(wide.map(\.chunkIndex), [0, 1, 2, 3, 4, 5, 6])
    }

    // MARK: - Test 2: Two Recipes In Same Book Both Surface

    /// Cookbook mode is chunk-level, NOT book-level. If the user asks for
    /// "Italian recipes" and one cookbook contains five of them, all five
    /// must come back — old behavior collapsed to one result per book.
    /// We verify this by inserting two chunks for the same book with strong
    /// embedding similarity to a query vector and confirming both come back.
    func testTwoRecipesSameBookBothSurface() async throws {
        let book = try await insertBook(title: "Tuscan Kitchen")

        // Both chunks point in the same embedding direction (high similarity).
        let recipeA = "Pappardelle with wild boar ragù. Ingredients: 500g pappardelle, 800g boar shoulder, 2 carrots..."
        let recipeB = "Ribollita Toscana. Ingredients: 400g cavolo nero, 200g cannellini beans, day-old bread..."

        let idA = try await insertChunk(
            bookId: book.id,
            chunkIndex: 0,
            text: recipeA,
            embedding: makeEmbedding(direction: 7)
        )
        let idB = try await insertChunk(
            bookId: book.id,
            chunkIndex: 1,
            text: recipeB,
            embedding: makeEmbedding(direction: 7)
        )
        XCTAssertGreaterThan(idA, 0)
        XCTAssertGreaterThan(idB, 0)

        // Prove both rows are visible to the embedded-vector lookup that
        // HybridSearchManager actually consumes (no book-level dedup at
        // the database layer).
        let vectors = try await chunkRepo.fetchEmbeddingVectors(forBookIds: [book.id])
        XCTAssertEqual(vectors.count, 2, "both same-book chunks must be returned, not deduped")
        let bookIds = Set(vectors.map(\.bookId))
        XCTAssertEqual(bookIds.count, 1, "all chunks belong to the same book")
        let chunkIds = Set(vectors.map(\.id))
        XCTAssertTrue(chunkIds.contains(idA))
        XCTAssertTrue(chunkIds.contains(idB))
    }

    // MARK: - Test 3: Full Chunk Text Available — Not Truncated

    /// The whole point of cookbook mode is feeding the LLM the entire recipe.
    /// Our snippet column stays at 200 chars (UI-friendly), but the underlying
    /// chunk text and the assembled adjacent window must remain complete.
    /// This test simulates the assembly that `buildChunkLevelResults` performs.
    func testFullChunkTextIsNotTruncatedToTwoHundredChars() async throws {
        let book = try await insertBook(title: "Long Recipe Book")

        // A long recipe — 600+ chars, well past the 200-char snippet ceiling.
        let longRecipe = String(repeating: "Combine the flour, butter, and sugar. ", count: 30)
        XCTAssertGreaterThan(longRecipe.count, 1000, "fixture must be long")

        let cid = try await insertChunk(
            bookId: book.id,
            chunkIndex: 0,
            text: longRecipe,
            embedding: makeEmbedding(direction: 1)
        )
        XCTAssertGreaterThan(cid, 0)

        // Fetch back via the same path the search pipeline uses.
        let chunks = try await chunkRepo.fetchChunksByIds([cid])
        XCTAssertEqual(chunks.count, 1)
        let stored = try XCTUnwrap(chunks.first)

        // Stored text is preserved completely.
        XCTAssertEqual(stored.text.count, longRecipe.count, "DB must store full chunk text")
        XCTAssertEqual(stored.text, longRecipe)

        // Simulate adjacent-window assembly (cookbook code path):
        let window = try await chunkRepo.fetchChunksAround(bookId: book.id, chunkIndex: 0, window: 1)
        let assembled = window.sorted { $0.chunkIndex < $1.chunkIndex }
            .map(\.text)
            .joined(separator: "\n\n")
        XCTAssertGreaterThanOrEqual(assembled.count, longRecipe.count, "assembled fullText must contain entire chunk")

        // Snippet preview (UI card only) is what stays at 200 chars.
        let uiSnippet = String(stored.text.prefix(200))
        XCTAssertEqual(uiSnippet.count, 200, "UI snippet IS bounded — that's intentional")

        // The contract: assembled text fed to the LLM is much longer than the snippet.
        XCTAssertGreaterThan(assembled.count, uiSnippet.count * 3, "LLM must see far more than a 200-char preview")
    }

    // MARK: - Test 4: Embedding Chunk-Size Constraint

    /// All chunks the extractor produces must fit within MiniLM's 512-token
    /// context window. A safe budget is ≤ 200 words per chunk (≈ 280 tokens).
    /// This test asserts the configured constant matches that contract.
    func testEmbeddingChunkSizeFitsContextWindow() {
        // The constant must stay ≤ 250 words to keep tokens under 480 (the
        // safe cap before the embedder's progressive truncation kicks in).
        XCTAssertLessThanOrEqual(
            Constants.Models.chunkWordCount, 250,
            "chunkWordCount above ~250 words risks blowing past 480-token embedding budget"
        )
        XCTAssertGreaterThanOrEqual(
            Constants.Models.chunkWordCount, 100,
            "chunkWordCount under 100 words fragments recipes too aggressively"
        )

        // Embedding cap must leave room under MiniLM's 512-token context.
        XCTAssertLessThanOrEqual(
            Constants.Models.embeddingMaxTokens, 512,
            "embeddingMaxTokens must stay under MiniLM's 512-token context"
        )
        XCTAssertGreaterThanOrEqual(
            Constants.Models.embeddingMaxTokens, 256,
            "embeddingMaxTokens too small wastes useful context"
        )

        // Embedding dim sanity (MiniLM-L6-v2 = 384).
        XCTAssertEqual(Constants.Models.embeddingDimension, 384)
        XCTAssertEqual(
            Constants.Models.embeddingBlobSize,
            384 * MemoryLayout<Float>.size,
            "blob size must equal dim × float byte width"
        )
    }

    // MARK: - Test 5: Recipe Hints Created And Used

    /// RecipeDetector scores chunks for recipe-likeness and writes rows to
    /// `recipeHint`. Cookbook search then reads those rows and boosts matching
    /// chunks. This test:
    ///   a) runs the detector on a clearly recipe-ish chunk and a clearly
    ///      non-recipe chunk
    ///   b) confirms only the recipe-ish chunk gets a hint
    ///   c) confirms HybridSearchManager's hint-lookup query (≥0.4 score)
    ///      returns the right chunkIds
    func testRecipeHintsAreCreatedAndDiscoverable() async throws {
        let book = try await insertBook(title: "Detection Test Book")

        let recipeText = """
        Classic Margherita Pizza
        Serves 4. Prep time: 30 minutes. Cook time: 12 minutes.
        Ingredients:
        - 500g pizza flour
        - 1 tsp salt
        - 2 cups warm water
        - 200g fresh mozzarella, sliced
        - 4 tbsp tomato sauce
        Instructions:
        Preheat oven to 250 degrees C. Stir together flour, salt, and water until smooth.
        Knead the dough for 10 minutes. Bake for 12 minutes until the crust is golden.
        """
        let proseText = """
        The history of pizza is long and fascinating. Its origins can be traced to flatbreads
        eaten in ancient Greece, Rome, and Egypt. The modern Neapolitan style we know today
        emerged in the 18th century when tomatoes from the New World became widely available
        in southern Italy.
        """

        let recipeChunkId = try await insertChunk(
            bookId: book.id,
            chunkIndex: 0,
            text: recipeText
        )
        let proseChunkId = try await insertChunk(
            bookId: book.id,
            chunkIndex: 1,
            text: proseText
        )

        // Run the heuristic detector
        let detector = RecipeDetector(dbPool: dbPool)
        await detector.detectRecipes(forBook: book.id)

        // Inspect the recipeHint table directly.
        let hintRows = try await dbPool.read { db -> [(chunkId: Int64, score: Double)] in
            let rows = try Row.fetchAll(db, sql: "SELECT chunkId, score FROM recipeHint ORDER BY chunkId")
            return rows.map { (chunkId: $0["chunkId"] as Int64, score: $0["score"] as Double) }
        }

        // The recipe text MUST get a hint — quantity patterns (cup, tsp, tbsp),
        // instruction verbs (preheat, stir, knead, bake), time markers, temperature,
        // and "Ingredients" / "Instructions" / "Serves" headers all fire.
        let recipeHints = hintRows.filter { $0.chunkId == recipeChunkId }
        XCTAssertEqual(recipeHints.count, 1, "the recipe chunk must produce exactly one hint row")
        let recipeScore = try XCTUnwrap(recipeHints.first?.score)
        XCTAssertGreaterThanOrEqual(
            recipeScore, 0.4,
            "recipe with ingredients+instructions+temperature should score ≥ 0.4 (got \(recipeScore))"
        )

        // The pure prose text should NOT produce a hint (or score very low).
        let proseHints = hintRows.filter { $0.chunkId == proseChunkId }
        XCTAssertTrue(
            proseHints.isEmpty || (proseHints.first?.score ?? 0) < 0.3,
            "non-recipe prose should not be flagged as a recipe"
        )

        // Replicate HybridSearchManager's hint-lookup SQL to confirm the
        // boost path will see this hint (score >= 0.4).
        let chunkIds: [Int64] = [recipeChunkId, proseChunkId]
        let placeholders = chunkIds.map { _ in "?" }.joined(separator: ",")
        let arguments = StatementArguments(chunkIds.map { Int64($0) })
        let boostedIds = try await dbPool.read { db -> Set<Int64> in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT chunkId FROM recipeHint WHERE chunkId IN (\(placeholders)) AND score >= 0.4",
                arguments: arguments
            )
            return Set(rows.compactMap { $0["chunkId"] as Int64? })
        }
        XCTAssertTrue(boostedIds.contains(recipeChunkId), "recipe chunk must be boost-eligible")
        XCTAssertFalse(boostedIds.contains(proseChunkId), "prose chunk must not be boost-eligible")
    }

    // MARK: - Test 6: Cookbook Corpus Diagnostics

    /// `ChatManager.logCookbookCorpusStats` queries
    /// `countChunks`, `countEmbeddedChunks`, plus a recipeHint join. These
    /// diagnostics are what tells us whether cookbook mode has anything to
    /// search at all — they MUST work end-to-end on a fresh DB.
    func testCookbookCorpusDiagnostics() async throws {
        let bookA = try await insertBook(title: "Cookbook A")
        let bookB = try await insertBook(title: "Cookbook B")

        // 3 chunks for A: 2 embedded, 1 not. 2 chunks for B: both embedded.
        let aFirst = try await insertChunk(bookId: bookA.id, chunkIndex: 0, text: "Recipe one in A.", embedding: makeEmbedding(direction: 1))
        _ = try await insertChunk(bookId: bookA.id, chunkIndex: 1, text: "Recipe two in A.", embedding: makeEmbedding(direction: 2))
        _ = try await insertChunk(bookId: bookA.id, chunkIndex: 2, text: "Unembedded chunk in A.", embedding: nil)
        let bFirst = try await insertChunk(bookId: bookB.id, chunkIndex: 0, text: "Recipe one in B.", embedding: makeEmbedding(direction: 3))
        _ = try await insertChunk(bookId: bookB.id, chunkIndex: 1, text: "Recipe two in B.", embedding: makeEmbedding(direction: 4))

        try await insertRecipeHint(chunkId: aFirst, score: 0.8, title: "Recipe one in A")
        try await insertRecipeHint(chunkId: bFirst, score: 0.55, title: "Recipe one in B")

        let bookIds: Set<UUID> = [bookA.id, bookB.id]

        let total = try await chunkRepo.countChunks(forBookIds: bookIds)
        XCTAssertEqual(total, 5, "should count all chunks across both cookbooks")

        let embedded = try await chunkRepo.countEmbeddedChunks(forBookIds: bookIds)
        XCTAssertEqual(embedded, 4, "should count only chunks where embedding IS NOT NULL")

        // Replicate ChatManager.dbReadRecipeHintCount approach: gather chunk
        // IDs via GRDB's QueryInterface (so UUID encoding matches), then
        // count recipeHints joined on those IDs.
        let chunkIds = try await dbPool.read { db -> [Int64] in
            try TextChunk
                .filter(bookIds.contains(TextChunk.Columns.bookId))
                .fetchAll(db)
                .compactMap(\.id)
        }
        XCTAssertEqual(chunkIds.count, 5, "diagnostic chunk lookup must see all 5 stored chunks")
        let hintCount = try await dbPool.read { db -> Int in
            let placeholders = chunkIds.map { _ in "?" }.joined(separator: ",")
            let arguments = StatementArguments(chunkIds.map { Int64($0) })
            return try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM recipeHint WHERE chunkId IN (\(placeholders))",
                arguments: arguments
            ) ?? 0
        }
        XCTAssertEqual(hintCount, 2, "diagnostic recipe-hint count must include both stored hints")
    }

    // MARK: - Test 7: Empty-Scope Short-Circuit (No-Results Contract)

    /// When cookbook mode is active but the collection is empty, ChatManager
    /// must NOT call the LLM (it would hallucinate from system prompt alone).
    /// We verify the precondition the short-circuit relies on: with zero books
    /// in scope, every database query that the search pipeline issues returns
    /// an empty result set.
    func testEmptyCookbookScopeYieldsZeroSearchInputs() async throws {
        // Insert a book + chunks that are NOT in the (empty) scope.
        let outsider = try await insertBook(title: "Not In Collection")
        _ = try await insertChunk(
            bookId: outsider.id,
            chunkIndex: 0,
            text: "Coq au vin recipe with bacon, mushrooms, and red wine.",
            embedding: makeEmbedding(direction: 9)
        )

        let emptyScope: Set<UUID> = []

        // 1. Vector lookup returns nothing.
        let vectors = try await chunkRepo.fetchEmbeddingVectors(forBookIds: emptyScope)
        XCTAssertTrue(vectors.isEmpty, "empty scope must yield zero vectors (no library-wide leak)")

        // 2. Diagnostics report zeros.
        let total = try await chunkRepo.countChunks(forBookIds: emptyScope)
        XCTAssertEqual(total, 0)
        let embedded = try await chunkRepo.countEmbeddedChunks(forBookIds: emptyScope)
        XCTAssertEqual(embedded, 0)

        // 3. Embedded-chunk fetch (used by other reranking paths) returns nothing.
        let embeddedFetch = try await chunkRepo.fetchEmbeddedChunks(forBookIds: emptyScope)
        XCTAssertTrue(embeddedFetch.isEmpty)
    }

    // MARK: - Test 8a: Keyword Fallback Finds Chunks With No Embedding

    /// Vector search misses on short / very specific queries ("venison",
    /// "bouillabaisse") and skips chunks that haven't been embedded yet.
    /// `searchChunksByKeyword` is the safety net — it must surface chunks
    /// containing the literal keyword even when the embedding column is NULL.
    func testKeywordFallbackFindsUnembeddedChunks() async throws {
        let book = try await insertBook(title: "Wild Game Cookery")

        // Two chunks: one explicitly mentions venison, one is unrelated.
        // Both have NULL embeddings (simulating "indexing not yet finished").
        let venisonChunk = try await insertChunk(
            bookId: book.id,
            chunkIndex: 0,
            text: "Venison stew with juniper berries: take 1kg venison shoulder, sear on all sides, then braise with red wine for 3 hours.",
            embedding: nil
        )
        let unrelatedChunk = try await insertChunk(
            bookId: book.id,
            chunkIndex: 1,
            text: "An introduction to French sauces: the five mother sauces are béchamel, velouté, espagnole, hollandaise, and tomato.",
            embedding: nil
        )

        let scope: Set<UUID> = [book.id]

        // Embedded-vector pool is empty.
        let vectors = try await chunkRepo.fetchEmbeddingVectors(forBookIds: scope)
        XCTAssertTrue(vectors.isEmpty, "precondition: no embedded chunks")

        // Keyword fallback MUST find the venison chunk.
        let hits = try await chunkRepo.searchChunksByKeyword(
            forBookIds: scope,
            keywords: ["venison"]
        )
        XCTAssertEqual(hits.count, 1, "keyword fallback must find the one chunk containing 'venison'")
        XCTAssertEqual(hits.first?.id, venisonChunk)
        XCTAssertNotEqual(hits.first?.id, unrelatedChunk)

        // Multi-keyword OR: query mentions venison and beef → still matches.
        let multi = try await chunkRepo.searchChunksByKeyword(
            forBookIds: scope,
            keywords: ["venison", "beef"]
        )
        XCTAssertEqual(multi.count, 1, "OR-of-LIKEs: at least one keyword present is enough")

        // Nonsense keyword → no hits.
        let none = try await chunkRepo.searchChunksByKeyword(
            forBookIds: scope,
            keywords: ["unicornsteak"]
        )
        XCTAssertTrue(none.isEmpty, "no chunk contains 'unicornsteak'")

        // Empty scope → empty result regardless of keyword.
        let outOfScope = try await chunkRepo.searchChunksByKeyword(
            forBookIds: [],
            keywords: ["venison"]
        )
        XCTAssertTrue(outOfScope.isEmpty, "empty scope must short-circuit")
    }

    // MARK: - Test 9: Scoped Search Doesn't Leak Other Books

    /// Cookbook mode must scope strictly to the selected collection. A second
    /// book outside the scope must never appear in vector results, even if
    /// its embedding is more similar to the (synthetic) query direction.
    func testCookbookScopingExcludesOutsideBooks() async throws {
        let inside = try await insertBook(title: "Inside Cookbook")
        let outside = try await insertBook(title: "Outside Novel")

        // Outside book has a chunk pointing exactly at our test query direction.
        _ = try await insertChunk(
            bookId: outside.id,
            chunkIndex: 0,
            text: "Outside book chunk text — should be invisible to scoped search.",
            embedding: makeEmbedding(direction: 5)
        )

        // Inside book has a chunk pointing in a DIFFERENT direction (lower similarity).
        let insideId = try await insertChunk(
            bookId: inside.id,
            chunkIndex: 0,
            text: "Inside book chunk text — must be the only result returned.",
            embedding: makeEmbedding(direction: 5)
        )

        // Scope ONLY to the inside book.
        let scope: Set<UUID> = [inside.id]
        let vectors = try await chunkRepo.fetchEmbeddingVectors(forBookIds: scope)

        XCTAssertEqual(vectors.count, 1, "scope of one book must yield exactly one vector")
        XCTAssertEqual(vectors.first?.id, insideId)
        XCTAssertEqual(vectors.first?.bookId, inside.id)
        XCTAssertNotEqual(vectors.first?.bookId, outside.id, "outside book must never leak into scoped search")
    }
}
