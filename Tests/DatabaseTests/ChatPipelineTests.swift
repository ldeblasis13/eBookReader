import XCTest
import GRDB
@testable import EBookReader

/// Chat / cookbook pipeline regressions:
///   1. Recipe cards built by ChatManager survive into the chat session
///      (they used to be dropped, so RecipeCardView never rendered).
///   2. Prompts are budgeted: excerpts give way before the system prompt
///      or the question, and the Gemma turn template stays well formed.
///   3. Cookbook FTS chunk search scopes to the collection inside SQL,
///      before LIMIT, so out-of-scope hits can't crowd it out.
///   4. The pooled-embedding migration clears stale vectors for rebuild.
///
/// No llama model is loaded; token counts come from a whitespace word
/// counter, which is all ChatPromptBuilder's budgeting logic needs.
final class ChatPipelineTests: XCTestCase {

    // MARK: - Recipes pass-through

    @MainActor
    func testAssistantReplyKeepsRecipeCards() throws {
        let bookId = UUID()
        let recipe = ChatMessage.ParsedRecipe(
            title: "Roast Venison Loin",
            ingredients: ["1.5 kg venison loin", "sea salt"],
            instructions: "Roast for 25 minutes.",
            bookTitle: "Wild Game Cookery",
            bookId: bookId,
            position: .epub(spineIndex: 4, href: "ch5.xhtml"),
            completeness: "complete recipe"
        )
        let reference = ChatMessage.BookReference(
            bookId: bookId,
            bookTitle: "Wild Game Cookery",
            snippet: "Roast venison loin…",
            isRecipe: true
        )
        let reply = ChatMessage(
            role: .assistant,
            content: "Recipe 1: Roast Venison Loin",
            references: [reference],
            recipes: [recipe]
        )

        let session = ChatSession()
        session.appendUserMessage("venison")
        session.appendAssistantMessage(reply)

        let stored = try XCTUnwrap(session.messages.last)
        XCTAssertEqual(stored.role, .assistant)
        XCTAssertEqual(stored.recipes.count, 1, "recipe cards must reach the session, or RecipeCardView never renders")
        XCTAssertEqual(stored.recipes.first?.title, "Roast Venison Loin")
        XCTAssertEqual(stored.recipes.first?.bookId, bookId)
        XCTAssertEqual(stored.references.count, 1)
        XCTAssertEqual(stored.content, reply.content)
    }

    // MARK: - Prompt budgeting

    private let countWords: @Sendable ([String]) async -> [Int] = { texts in
        texts.map { $0.split(whereSeparator: \.isWhitespace).count }
    }

    private func words(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    private func excerpt(_ n: Int, words count: Int) -> ChatPromptBuilder.Excerpt {
        ChatPromptBuilder.Excerpt(
            header: "[excerpt \(n) | \"Game Cookery\" | id=\(n)]",
            text: (1...count).map { "e\(n)w\($0)" }.joined(separator: " ")
        )
    }

    private let questionTail = "\nUser question: What can I cook with venison?<end_of_turn>\n<start_of_turn>model\n"

    /// With room to spare, the prompt is exactly the established single-turn
    /// format the cookbook system prompt and response parser are tuned for.
    func testPromptFormatWhenEverythingFits() async {
        let result = await ChatPromptBuilder.build(
            systemPrompt: "SYS RULES",
            excerpts: [ChatPromptBuilder.Excerpt(header: "[excerpt 1 | \"Book\" | id=1]", text: "Text one")],
            history: [],
            question: "Q?",
            tokenBudget: 10_000,
            countTokens: countWords
        )
        let expected = "<start_of_turn>user\nSYS RULES\n"
            + "\nBEGIN BOOK EXCERPTS (this is the ONLY information you may use to answer):\n\n"
            + "[excerpt 1 | \"Book\" | id=1]\nText one\n\n"
            + "END BOOK EXCERPTS\n"
            + "\nUser question: Q?<end_of_turn>\n<start_of_turn>model\n"
        XCTAssertEqual(result.prompt, expected)
        XCTAssertEqual(result.includedExcerptCount, 1)
        XCTAssertFalse(result.lastExcerptTrimmed)
    }

    /// Five 300-word excerpts against a 1000-token budget: the two best fit
    /// whole, the third is trimmed into what's left, the rest are dropped —
    /// and the system prompt and question are untouched.
    func testOverflowTrimsAndDropsExcerptsButKeepsQuestion() async {
        let budget = 1000
        let result = await ChatPromptBuilder.build(
            systemPrompt: "SYS RULES",
            excerpts: (1...5).map { excerpt($0, words: 300) },
            history: [],
            question: "What can I cook with venison?",
            tokenBudget: budget,
            countTokens: countWords
        )

        XCTAssertTrue(result.prompt.hasPrefix("<start_of_turn>user\nSYS RULES\n"), "system prompt must lead the prompt intact")
        XCTAssertTrue(result.prompt.hasSuffix(questionTail), "question and model-turn marker must end the prompt intact")
        XCTAssertLessThanOrEqual(words(result.prompt), budget, "prompt must fit the budget")

        XCTAssertEqual(result.includedExcerptCount, 3, "excerpts kept must be a prefix: two whole, one trimmed")
        XCTAssertTrue(result.lastExcerptTrimmed)
        XCTAssertTrue(result.prompt.contains("e1w300\n"), "best excerpt kept whole")
        XCTAssertTrue(result.prompt.contains("e2w300\n"), "second excerpt kept whole")
        XCTAssertTrue(result.prompt.contains("[excerpt 3 "))
        XCTAssertFalse(result.prompt.contains("e3w300"), "third excerpt is cut short")
        XCTAssertTrue(result.prompt.contains(ChatPromptBuilder.trimMarker))
        XCTAssertFalse(result.prompt.contains("[excerpt 4 "), "lower-ranked excerpts are dropped first")
        XCTAssertFalse(result.prompt.contains("[excerpt 5 "))
    }

    /// A budget too small for any excerpt still yields the full instructions
    /// and question rather than a prompt cut off mid-sentence.
    func testTinyBudgetDropsAllExcerptsButKeepsQuestion() async {
        let result = await ChatPromptBuilder.build(
            systemPrompt: "SYS RULES",
            excerpts: (1...3).map { excerpt($0, words: 300) },
            history: [],
            question: "What can I cook with venison?",
            tokenBudget: 150,
            countTokens: countWords
        )
        XCTAssertEqual(result.includedExcerptCount, 0)
        XCTAssertTrue(result.prompt.contains(ChatPromptBuilder.noExcerptsNote))
        XCTAssertTrue(result.prompt.hasPrefix("<start_of_turn>user\nSYS RULES\n"))
        XCTAssertTrue(result.prompt.hasSuffix(questionTail))
    }

    /// The session appends the user's message before asking, so history ends
    /// with the current question. It must appear once, in a well-formed
    /// user/model alternation that ends on an open model turn.
    func testHistoryTemplateIsWellFormedAndQuestionAppearsOnce() async {
        let question = "And what about venison?"
        let history = [
            ChatMessage(role: .user, content: "Tell me about bread"),
            ChatMessage(role: .assistant, content: "Bread is flour and water."),
            ChatMessage(role: .user, content: question),
        ]
        let result = await ChatPromptBuilder.build(
            systemPrompt: "SYS RULES",
            excerpts: [excerpt(1, words: 20)],
            history: history,
            question: question,
            tokenBudget: 10_000,
            countTokens: countWords
        )
        let prompt = result.prompt

        XCTAssertEqual(prompt.components(separatedBy: question).count - 1, 1, "current question must appear exactly once")
        XCTAssertEqual(result.includedHistoryCount, 2)
        XCTAssertTrue(prompt.hasPrefix("<start_of_turn>user\nSYS RULES\n\nTell me about bread<end_of_turn>\n"),
                      "system prompt opens the first user turn, followed by the earliest exchange")

        // Turn markers must alternate user → model, each closed, ending on an open model turn.
        let markers = ["<start_of_turn>user", "<start_of_turn>model", "<end_of_turn>"]
        var sequence: [String] = []
        var searchStart = prompt.startIndex
        while true {
            var earliest: (marker: String, range: Range<String.Index>)?
            for marker in markers {
                guard let range = prompt.range(of: marker, range: searchStart..<prompt.endIndex) else { continue }
                if earliest == nil || range.lowerBound < earliest!.range.lowerBound {
                    earliest = (marker, range)
                }
            }
            guard let found = earliest else { break }
            sequence.append(found.marker)
            searchStart = found.range.upperBound
        }
        XCTAssertEqual(sequence, [
            "<start_of_turn>user", "<end_of_turn>",
            "<start_of_turn>model", "<end_of_turn>",
            "<start_of_turn>user", "<end_of_turn>",
            "<start_of_turn>model",
        ])

        // This question's excerpts belong to the final user turn.
        let finalUserTurn = prompt.range(of: "<start_of_turn>user", options: .backwards)!
        XCTAssertNotNil(prompt.range(of: "[excerpt 1 ", range: finalUserTurn.upperBound..<prompt.endIndex))
    }

    /// Long conversations keep only their newest exchanges, within a share
    /// of the budget, so the excerpts still get room.
    func testHistoryKeepsNewestExchangesWithinItsShare() async {
        var history: [ChatMessage] = []
        for i in 1...10 {
            let filler = Array(repeating: "w", count: 99).joined(separator: " ")
            history.append(ChatMessage(role: .user, content: "Q-\(i)- \(filler)"))
            history.append(ChatMessage(role: .assistant, content: "A-\(i)- \(filler)"))
        }
        let result = await ChatPromptBuilder.build(
            systemPrompt: "SYS RULES",
            excerpts: [excerpt(1, words: 200)],
            history: history,
            question: "Next?",
            tokenBudget: 2000,
            countTokens: countWords
        )
        // ~1900 tokens of room → ~475 for history → two ~202-token exchanges.
        XCTAssertEqual(result.includedHistoryCount, 4)
        XCTAssertTrue(result.prompt.contains("Q-10- "))
        XCTAssertTrue(result.prompt.contains("Q-9- "))
        XCTAssertFalse(result.prompt.contains("Q-8- "), "older exchanges are dropped first")
        XCTAssertFalse(result.prompt.contains("Q-1- "))
        XCTAssertEqual(result.includedExcerptCount, 1, "history must not crowd out the excerpts")
        XCTAssertFalse(result.lastExcerptTrimmed)
        XCTAssertLessThanOrEqual(words(result.prompt), 2000)
    }

    // MARK: - Database-backed tests

    private var tempDir: URL!
    private var dbPool: DatabasePool!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("EBookReaderChatTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        dbPool = try DatabasePool(path: tempDir.appendingPathComponent("chat_test.sqlite").path)
        try dbPool.write { db in
            // Same ftsContent definition as DatabaseManager v3.
            try db.execute(sql: """
                CREATE VIRTUAL TABLE ftsContent USING fts5(
                    text,
                    bookId UNINDEXED,
                    chunkIndex UNINDEXED,
                    tokenize='porter unicode61'
                )
            """)
            // Just the columns the embedding reset touches.
            try db.execute(sql: "CREATE TABLE book (id TEXT PRIMARY KEY NOT NULL, embeddingIndexed BOOLEAN NOT NULL DEFAULT 0)")
            try db.execute(sql: "CREATE TABLE textChunk (id INTEGER PRIMARY KEY AUTOINCREMENT, bookId TEXT NOT NULL, text TEXT NOT NULL, embedding BLOB)")
        }
    }

    override func tearDownWithError() throws {
        dbPool = nil
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
    }

    // MARK: - FTS chunk scoping

    /// 300 out-of-collection rows outrank the one in-collection recipe. The
    /// old query took a library-wide top `limit * 4` and filtered afterwards,
    /// so the in-collection hit vanished; scoping in SQL must still find it.
    func testCookbookChunkSearchScopesBeforeLimit() async throws {
        let cookbook = UUID()
        try await dbPool.write { db in
            for i in 0..<300 {
                try db.execute(
                    sql: "INSERT INTO ftsContent(text, bookId, chunkIndex) VALUES (?, ?, ?)",
                    arguments: ["venison venison venison", UUID().uuidString, i]
                )
            }
            try db.execute(
                sql: "INSERT INTO ftsContent(text, bookId, chunkIndex) VALUES (?, ?, ?)",
                arguments: [
                    "Braised shoulder of venison with juniper, red wine, carrots, onions, thyme and a long slow cook in a low oven until tender.",
                    cookbook.uuidString,
                    7,
                ]
            )
        }

        let fts = FullTextSearchManager(dbPool: dbPool)
        let hits = await fts.searchChunks(query: "venison", scopedBookIds: [cookbook], limit: 10)

        XCTAssertEqual(hits.count, 1, "the in-collection recipe must survive 300 better-ranked out-of-scope hits")
        XCTAssertEqual(hits.first?.bookId, cookbook)
        XCTAssertEqual(hits.first?.chunkIndex, 7)
        XCTAssertTrue(hits.first?.text.contains("juniper") == true)
    }

    // MARK: - Pooled-embedding migration

    func testEmbeddingResetClearsVectorsAndFlagsButKeepsChunks() async throws {
        try await dbPool.write { db in
            try db.execute(sql: "INSERT INTO book (id, embeddingIndexed) VALUES ('a', 1), ('b', 0)")
            try db.execute(
                sql: "INSERT INTO textChunk (bookId, text, embedding) VALUES ('a', 'one', ?), ('a', 'two', ?), ('b', 'three', NULL)",
                arguments: [Data(repeating: 1, count: 16), Data(repeating: 2, count: 16)]
            )
            try DatabaseManager.clearEmbeddingsForRebuild(db)
        }

        let (indexedBooks, embeddedChunks, chunks) = try await dbPool.read { db in
            (
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM book WHERE embeddingIndexed = 1") ?? -1,
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM textChunk WHERE embedding IS NOT NULL") ?? -1,
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM textChunk") ?? -1
            )
        }
        XCTAssertEqual(indexedBooks, 0, "every book must be queued for re-embedding")
        XCTAssertEqual(embeddedChunks, 0, "old per-token vectors must not be mixed with pooled ones")
        XCTAssertEqual(chunks, 3, "chunk rows (and the recipe hints keyed on them) are kept")
    }
}
