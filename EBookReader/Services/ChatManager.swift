import Foundation
import GRDB
import os

/// Orchestrates the RAG chat pipeline: user query → retrieve context → generate response.
actor ChatManager {
    private let hybridSearchManager: HybridSearchManager
    private let llmEngine: LLMEngine
    private let chunkRepository: TextChunkRepository
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "EBookReader",
        category: "ChatManager"
    )

    private let maxContextChunks = 10
    private let maxResponseTokens = 2048
    /// Prompt budget used only when the generation model can't report its
    /// own (it failed to load, so generate() will surface that error anyway).
    private let fallbackPromptTokenBudget = 8192
    /// Max words per summarization batch (~6000 tokens fits comfortably in context)
    private let summaryBatchWords = 4000

    init(hybridSearchManager: HybridSearchManager, llmEngine: LLMEngine, chunkRepository: TextChunkRepository) {
        self.hybridSearchManager = hybridSearchManager
        self.llmEngine = llmEngine
        self.chunkRepository = chunkRepository
    }

    // MARK: - System Prompts

    private let librarySystemPrompt = """
    You are a librarian assistant with access to the user's personal book library. \
    The excerpts below were found by searching their library. \
    STRICT RULES: \
    1. ONLY use information from the provided excerpts. Do NOT use your general knowledge. \
    2. Always cite which book each piece of information comes from using [Book Title]. \
    3. If the excerpts contain recipes, ingredients, or instructions, present them clearly. \
    4. If the excerpts don't contain enough information, say what you found and suggest the user try a more specific query. \
    5. Never invent or hallucinate information not in the excerpts. \
    6. When listing multiple items (recipes, topics, references), number them clearly. \
    7. If the user seems to be asking about a specific book, focus your answer on excerpts from that book.
    """

    private let cookbookSystemPrompt = """
    You are a recipe extractor for the user's personal cookbook library.
    The excerpts below are real text from the user's cookbooks. You can ONLY reference what is visible in these excerpts.

    ABSOLUTE RULES — VIOLATING ANY RULE IS A FAILURE:
    1. NEVER invent a recipe, ingredient, quantity, cooking time, temperature, instruction, or technique.
    2. NEVER reference a book title or author that does not appear in the excerpts below.
    3. Each excerpt is labeled with [excerpt N | "Book Title" | id=chunkId]. Cite the book title exactly as shown — do not paraphrase or shorten it.
    4. For each recipe you find in the excerpts, output it in this exact format:

       Recipe N: <recipe name as it appears>
       From: <Book Title>
       Excerpt: [excerpt N]
       Ingredients (visible in excerpt):
       - <ingredient 1>
       - <ingredient 2>
       ...
       Instructions (visible in excerpt):
       <one paragraph or short numbered steps — only what is in the excerpt>
       Notes: <only if visible in excerpt; otherwise omit>
       Completeness: <one of "complete recipe" | "partial recipe — open the book for the full version">

    5. If the excerpts contain only a partial recipe (missing ingredients list, missing instructions, missing quantities), mark Completeness as "partial recipe" and DO NOT fill in the gaps.
    6. If the user asks for a count (e.g. "5 recipes"), return up to that many — but only as many as are actually visible in the excerpts.
    7. If the user mentions ingredients they have, only show recipes whose visible ingredients include them. Do not infer.
    8. If NO recipes are visible in the excerpts, respond ONLY with: "No matching recipes found in the provided excerpts."
    """

    // MARK: - Send Message

    var debugInfo: String?

    func setDebugInfo(_ info: String?) {
        debugInfo = info
    }

    /// Processes a user message: retrieves relevant context, generates a response.
    func sendMessage(
        _ text: String,
        books: [Book],
        history: [ChatMessage],
        currentBook: Book? = nil,
        isCookbookMode: Bool = false
    ) async -> ChatMessage {
        // Summarization shortcut (general chat only — cookbook mode never summarizes)
        if !isCookbookMode, let book = currentBook, isSummarizationQuery(text) {
            return await summarizeBook(book)
        }

        // Cookbook mode: hard fail if no books in scope (no library-wide fallback).
        if isCookbookMode && books.isEmpty {
            return ChatMessage(
                role: .assistant,
                content: "This cookbook collection is empty. Drag some cookbooks into it from the library, then ask me again."
            )
        }

        // Diagnostics: how much corpus does cookbook mode actually have?
        if isCookbookMode {
            await logCookbookCorpusStats(books: books)
        }

        // Step 1: Search the library for relevant content.
        let options: HybridSearchManager.Options = isCookbookMode ? .cookbook : .general
        var searchResults = await hybridSearchManager.search(query: text, books: books, options: options)

        // For general chat: if scoped search yielded little, also try the open book.
        // Cookbook mode does NOT fall back outside the selected collection.
        if !isCookbookMode, let book = currentBook, searchResults.count < 3 {
            let bookOnly = await hybridSearchManager.search(query: text, books: [book], options: .general)
            var seen = Set(searchResults.map(\.bookId))
            for r in bookOnly where !seen.contains(r.bookId) {
                searchResults.append(r)
                seen.insert(r.bookId)
            }
        }

        let topResults = Array(searchResults.prefix(maxContextChunks))

        // No results → don't call the LLM (it would hallucinate).
        if topResults.isEmpty {
            let noResultsMsg: String
            if isCookbookMode {
                // Distinguish "AI index missing" from "everything indexed but
                // your query found nothing" so the user knows whether to wait,
                // repair, or rephrase.
                let bookIds = Set(books.map(\.id))
                let totalChunks = (try? await chunkRepository.countChunks(forBookIds: bookIds)) ?? 0
                let embeddedChunks = (try? await chunkRepository.countEmbeddedChunks(forBookIds: bookIds)) ?? 0
                let ftsCount = (try? await dbCountFTSRows(forBookIds: bookIds)) ?? 0

                if totalChunks == 0 && ftsCount == 0 {
                    noResultsMsg = "Your \(books.count) cookbook(s) aren't indexed yet — neither full-text nor AI index has any rows. Give indexing a minute and try again. If it stays empty, try right-clicking the collection and choosing Rebuild Index."
                } else if totalChunks == 0 {
                    noResultsMsg = "Full-text index is ready (\(ftsCount) rows) but the AI recipe index hasn't run yet for your \(books.count) cookbook(s) (0 chunks). The app should now build it automatically — give it a couple minutes. If nothing changes, right-click the collection → Rebuild Index."
                } else if embeddedChunks == 0 {
                    noResultsMsg = "Your \(books.count) cookbook(s) have \(totalChunks) text chunks but no embeddings yet. Wait for embedding to finish, then try again."
                } else {
                    noResultsMsg = "No matches in your cookbook collection (\(books.count) books, \(totalChunks) chunks, \(embeddedChunks) embedded, \(ftsCount) FTS rows). Try a different ingredient name, a cuisine, or a dish name."
                }
            } else {
                noResultsMsg = "I couldn't find relevant information in your books for that query. Try rephrasing or using different keywords."
            }
            return ChatMessage(role: .assistant, content: noResultsMsg)
        }

        // Diagnostics: log what we're sending into the prompt.
        if isCookbookMode {
            let totalWords = topResults.reduce(0) { $0 + $1.wordCount }
            let recipeHits = topResults.filter(\.isRecipeHit).count
            let chunkIds = topResults.compactMap(\.chunkId)
            logger.info("Cookbook context: \(topResults.count) chunks, \(recipeHits) recipe-hinted, ~\(totalWords) words, chunkIds=\(chunkIds)")
        }

        // Step 2: Build prompt with full chunk text and stable IDs, within the
        // model's context. If it doesn't all fit, the lowest-ranked excerpts
        // are trimmed or dropped — never the system prompt or the question.
        let built = await buildPrompt(userQuery: text, context: topResults, history: history, isCookbookMode: isCookbookMode)
        let promptResults = Array(topResults.prefix(built.includedExcerptCount))
        if promptResults.count < topResults.count || built.lastExcerptTrimmed {
            logger.warning("Prompt budget: kept \(promptResults.count) of \(topResults.count) excerpts (last one trimmed: \(built.lastExcerptTrimmed))")
        }

        // Step 3: Generate response. Cookbook mode uses low temperature (extraction task).
        let temperature: Float = isCookbookMode ? 0.1 : 0.7
        let topP: Float = isCookbookMode ? 0.5 : 0.9

        let responseText: String
        do {
            responseText = try await llmEngine.generate(
                prompt: built.prompt,
                maxTokens: maxResponseTokens,
                temperature: temperature,
                topP: topP
            )
        } catch {
            logger.error("Generation failed: \(error)")
            let extra = debugInfo ?? "no additional info"
            responseText = "Unable to generate: \(error.localizedDescription). Debug: \(extra)"
        }

        // Step 4: Build references from the excerpts the model actually saw.
        // Cookbook mode: keep ALL chunk references (multiple recipes from same book OK).
        // General mode: dedupe by book.
        let references: [ChatMessage.BookReference]
        if isCookbookMode {
            references = promptResults.compactMap { result in
                guard !result.snippet.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                return ChatMessage.BookReference(
                    bookId: result.bookId,
                    bookTitle: result.title,
                    author: result.author,
                    snippet: result.snippet,        // short for the card
                    position: result.position,
                    isRecipe: true
                )
            }
        } else {
            var seenBooks = Set<UUID>()
            references = promptResults.compactMap { result in
                guard !result.snippet.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                guard !seenBooks.contains(result.bookId) else { return nil }
                seenBooks.insert(result.bookId)
                return ChatMessage.BookReference(
                    bookId: result.bookId,
                    bookTitle: result.title,
                    author: result.author,
                    snippet: result.snippet,
                    position: result.position,
                    isRecipe: false
                )
            }
        }

        // Step 5: In cookbook mode, parse the model's structured response
        // into ParsedRecipe records so the UI can render proper cards
        // instead of a plaintext bubble. The system prompt forces the
        // "Recipe N: / From: / Ingredients: / Instructions:" format that
        // the parser keys on, and excerpt N → originating chunk gives us
        // the position the Open button needs.
        let parsedRecipes: [ChatMessage.ParsedRecipe]
        if isCookbookMode {
            let sources = promptResults.enumerated().map { (i, result) in
                RecipeResponseParser.ExcerptSource(
                    excerptIndex: i + 1,
                    bookId: result.bookId,
                    bookTitle: result.title,
                    author: result.author,
                    position: result.position
                )
            }
            parsedRecipes = RecipeResponseParser.parse(responseText, sources: sources)
            logger.info("Cookbook response: \(parsedRecipes.count) recipe card(s) parsed from \(promptResults.count) excerpt(s)")
        } else {
            parsedRecipes = []
        }

        return ChatMessage(
            role: .assistant,
            content: responseText,
            references: Array(references.prefix(isCookbookMode ? 10 : 5)),
            recipes: parsedRecipes
        )
    }

    // MARK: - Diagnostics

    private func logCookbookCorpusStats(books: [Book]) async {
        let bookIds = Set(books.map(\.id))
        let totalChunks = (try? await chunkRepository.countChunks(forBookIds: bookIds)) ?? 0
        let embeddedChunks = (try? await chunkRepository.countEmbeddedChunks(forBookIds: bookIds)) ?? 0
        let recipeHints = (try? await dbReadRecipeHintCount(forBookIds: bookIds)) ?? 0
        let ftsCount = (try? await dbCountFTSRows(forBookIds: bookIds)) ?? 0
        logger.info("Cookbook corpus: \(books.count) books, \(totalChunks) chunks, \(embeddedChunks) embedded, \(recipeHints) recipe hints, \(ftsCount) FTS rows")
    }

    /// Counts ftsContent rows scoped to the given books. The FTS5 table
    /// stores bookId as text (TextExtractor wrote `book.id.uuidString`),
    /// so we match against the same string form. Used by the diagnostic
    /// no-results message to tell the user whether FTS is available even
    /// when the AI index is empty.
    private func dbCountFTSRows(forBookIds bookIds: Set<UUID>) async throws -> Int {
        guard !bookIds.isEmpty else { return 0 }
        let placeholders = bookIds.map { _ in "?" }.joined(separator: ",")
        let arguments = StatementArguments(bookIds.map { $0.uuidString })
        return try await chunkRepository.dbPool.read { db in
            (try? Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM ftsContent WHERE bookId IN (\(placeholders))",
                arguments: arguments
            )) ?? 0
        }
    }

    private func dbReadRecipeHintCount(forBookIds bookIds: Set<UUID>) async throws -> Int {
        guard !bookIds.isEmpty else { return 0 }
        // Use GRDB QueryInterface so UUID encoding matches what was stored
        // (raw `.uuidString` interpolation does NOT match BLOB-encoded UUIDs).
        let chunkIds = try await chunkRepository.dbPool.read { db -> [Int64] in
            try TextChunk
                .filter(bookIds.contains(TextChunk.Columns.bookId))
                .fetchAll(db)
                .compactMap(\.id)
        }
        guard !chunkIds.isEmpty else { return 0 }
        return try await chunkRepository.dbPool.read { db in
            let placeholders = chunkIds.map { _ in "?" }.joined(separator: ",")
            let arguments = StatementArguments(chunkIds.map { Int64($0) })
            return (try? Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM recipeHint WHERE chunkId IN (\(placeholders))",
                arguments: arguments
            )) ?? 0
        }
    }

    // MARK: - Prompt Building

    /// Builds the LLM prompt. Uses `result.fullText` (NOT snippet) so the model
    /// sees the complete chunk plus any adjacent context the search expanded into.
    /// Sections are measured with the generation model's tokenizer so the
    /// prompt fits its context; see `ChatPromptBuilder` for what gives way.
    private func buildPrompt(
        userQuery: String,
        context: [HybridSearchManager.HybridSearchResult],
        history: [ChatMessage],
        isCookbookMode: Bool = false
    ) async -> ChatPromptBuilder.Result {
        let systemPrompt = isCookbookMode ? cookbookSystemPrompt : librarySystemPrompt
        let excerpts = context.enumerated().map { (i, result) in
            let titleEsc = result.title.replacingOccurrences(of: "\"", with: "\\\"")
            let chunkIdStr = result.chunkId.map(String.init) ?? "n/a"
            let recipeMark = result.isRecipeHit ? " | recipe-hint" : ""
            let header = isCookbookMode
                ? "[excerpt \(i + 1) | \"\(titleEsc)\" | id=\(chunkIdStr)\(recipeMark)]"
                : "--- Excerpt [\(i + 1)] from \"\(titleEsc)\" ---"
            return ChatPromptBuilder.Excerpt(header: header, text: result.fullText)
        }

        let llmEngine = self.llmEngine
        let modelBudget = try? await llmEngine.promptTokenBudget(maxResponseTokens: maxResponseTokens)
        let modelLoaded = modelBudget != nil

        return await ChatPromptBuilder.build(
            systemPrompt: systemPrompt,
            excerpts: excerpts,
            // Cookbook extraction is stateless — no conversation history.
            history: isCookbookMode ? [] : history,
            question: userQuery,
            tokenBudget: modelBudget ?? fallbackPromptTokenBudget,
            countTokens: { texts in
                // If the model didn't load, estimate rather than retrying the
                // load per call; ~3 chars per token overestimates English, so
                // the estimate errs toward fitting.
                if modelLoaded, let counts = try? await llmEngine.countTokens(texts) {
                    return counts
                }
                return texts.map { $0.utf8.count / 3 + 1 }
            }
        )
    }

    // MARK: - Book Summarization (Map-Reduce)

    private func isSummarizationQuery(_ text: String) -> Bool {
        let lower = text.lowercased()
        let keywords = ["summarize", "summary", "summarise", "overview",
                        "what is this book about", "what's this book about",
                        "tell me about this book", "describe this book",
                        "book summary", "book overview"]
        return keywords.contains(where: { lower.contains($0) })
    }

    private func summarizeBook(_ book: Book) async -> ChatMessage {
        logger.info("Starting map-reduce summarization for: \(book.displayTitle)")

        let chunks: [TextChunk]
        do {
            chunks = try await chunkRepository.fetchChunks(forBook: book.id)
        } catch {
            return ChatMessage(role: .assistant, content: "Couldn't load text for \"\(book.displayTitle)\". Make sure the book has been indexed.")
        }

        guard !chunks.isEmpty else {
            return ChatMessage(role: .assistant, content: "No indexed text found for \"\(book.displayTitle)\". The book may still be indexing.")
        }

        let batches = buildBatches(from: chunks)
        logger.info("Summarizing \(chunks.count) chunks in \(batches.count) batches")

        var batchSummaries: [String] = []
        for (i, batch) in batches.enumerated() {
            let batchText = batch.map(\.text).joined(separator: "\n\n")
            let prompt = """
            <start_of_turn>user
            Summarize the following section from the book "\(book.displayTitle)"\(book.author.map { " by \($0)" } ?? ""). \
            Capture the key points, themes, and important details. Be thorough but concise.

            --- TEXT ---
            \(batchText)
            --- END TEXT ---
            <end_of_turn>
            <start_of_turn>model
            """

            do {
                let summary = try await llmEngine.generate(prompt: prompt, maxTokens: 512)
                batchSummaries.append(summary)
                logger.info("Batch \(i + 1)/\(batches.count) summarized")
            } catch {
                logger.error("Batch \(i + 1) summarization failed: \(error)")
                batchSummaries.append("[Section \(i + 1) could not be summarized]")
            }
        }

        let combinedSummaries = batchSummaries.enumerated()
            .map { "Section \($0.offset + 1): \($0.element)" }
            .joined(separator: "\n\n")

        let reducePrompt = """
        <start_of_turn>user
        Below are summaries of different sections of the book "\(book.displayTitle)"\(book.author.map { " by \($0)" } ?? ""). \
        Combine them into a single, coherent, comprehensive summary of the entire book. \
        Include the main themes, key arguments or plot points, and the book's overall message or purpose. \
        Structure your summary with clear paragraphs.

        \(combinedSummaries)
        <end_of_turn>
        <start_of_turn>model
        """

        let finalSummary: String
        do {
            finalSummary = try await llmEngine.generate(prompt: reducePrompt, maxTokens: maxResponseTokens)
        } catch {
            finalSummary = "Summary of \"\(book.displayTitle)\":\n\n" + batchSummaries.joined(separator: "\n\n")
        }

        let reference = ChatMessage.BookReference(
            bookId: book.id,
            bookTitle: book.displayTitle,
            author: book.author,
            snippet: "Full book summary (\(chunks.count) sections analyzed)",
            position: nil
        )

        return ChatMessage(role: .assistant, content: finalSummary, references: [reference])
    }

    private func buildBatches(from chunks: [TextChunk]) -> [[TextChunk]] {
        var batches: [[TextChunk]] = []
        var currentBatch: [TextChunk] = []
        var currentWordCount = 0

        for chunk in chunks {
            let words = chunk.text.split(separator: " ").count
            if currentWordCount + words > summaryBatchWords && !currentBatch.isEmpty {
                batches.append(currentBatch)
                currentBatch = []
                currentWordCount = 0
            }
            currentBatch.append(chunk)
            currentWordCount += words
        }

        if !currentBatch.isEmpty {
            batches.append(currentBatch)
        }

        return batches
    }
}

// MARK: - Prompt Assembly

/// Builds Gemma chat prompts that fit the generation model's context.
///
/// Gemma has no system role, so the system prompt opens the first user turn.
/// Earlier exchanges follow as alternating user/model turns, and the final
/// user turn carries this question's excerpts and the question itself. When
/// it doesn't all fit, the oldest history goes first, then excerpts from the
/// lowest-ranked end (the last one kept may be trimmed). The system prompt
/// and the question are never cut.
enum ChatPromptBuilder {
    struct Excerpt: Sendable {
        let header: String
        let text: String
    }

    struct Result: Sendable {
        let prompt: String
        /// Number of excerpts in the prompt. Always a prefix of the input, so
        /// "excerpt N" in the prompt still refers to `excerpts[N - 1]`.
        let includedExcerptCount: Int
        /// True when the last included excerpt was cut short to fit.
        let lastExcerptTrimmed: Bool
        /// Prior messages kept in the prompt (user and model turns).
        let includedHistoryCount: Int
    }

    /// Slack for counting sections separately rather than the joined prompt.
    static let safetyMarginTokens = 64
    /// History may take at most this share of the room left after the system
    /// prompt and question, so a long conversation can't crowd out the
    /// excerpts the answer has to come from.
    static let maxHistoryShare = 0.25
    static let maxHistoryExchanges = 4
    /// A trimmed excerpt shorter than this isn't worth including.
    static let minTrimmedExcerptTokens = 128

    static let excerptsOpening = "\nBEGIN BOOK EXCERPTS (this is the ONLY information you may use to answer):\n\n"
    static let excerptsClosing = "END BOOK EXCERPTS\n"
    static let noExcerptsNote = "\nNo relevant excerpts were found in the user's book library.\n"
    static let trimMarker = " […]"

    /// One answered question from earlier in the conversation.
    private struct Exchange {
        let user: String
        let model: String
    }

    /// - Parameters:
    ///   - excerpts: Best-ranked first.
    ///   - history: The chat so far. A trailing user message is treated as
    ///     the current question and left out (the session appends it before
    ///     asking), so the question appears exactly once.
    ///   - tokenBudget: Prompt tokens the model accepts, including BOS.
    ///   - countTokens: Token count for each text, in order.
    static func build(
        systemPrompt: String,
        excerpts: [Excerpt],
        history: [ChatMessage],
        question: String,
        tokenBudget: Int,
        countTokens: @Sendable ([String]) async -> [Int]
    ) async -> Result {
        let candidates = Array(exchanges(from: history).suffix(maxHistoryExchanges))
        let skeleton = assemble(
            systemPrompt: systemPrompt,
            exchanges: [],
            excerptSection: excerptsOpening + excerptsClosing,
            question: question
        )
        let exchangeTexts = candidates.map(exchangeText)
        let blocks = excerpts.map { excerptBlock(header: $0.header, text: $0.text) }

        // One batched count for everything; only trimming needs more.
        let costs = await countTokens([skeleton] + exchangeTexts + blocks)
        let exchangeCosts = costs[1..<(1 + exchangeTexts.count)]
        let blockCosts = costs[(1 + exchangeTexts.count)...]

        // +1 for the BOS token generate() adds.
        var room = tokenBudget - costs[0] - 1 - safetyMarginTokens

        // History: newest exchanges first, whole exchanges only.
        var historyRoom = Int(Double(max(room, 0)) * maxHistoryShare)
        var keptExchanges: [Exchange] = []
        for (exchange, cost) in zip(candidates, exchangeCosts).reversed() {
            guard cost <= historyRoom else { break }
            keptExchanges.insert(exchange, at: 0)
            historyRoom -= cost
            room -= cost
        }

        // Excerpts: best-ranked first; stop at the first that doesn't fit,
        // trimming it into the remaining room when that's worthwhile.
        var keptBlocks: [String] = []
        var lastTrimmed = false
        for (index, cost) in zip(excerpts.indices, blockCosts) {
            if cost <= room {
                keptBlocks.append(blocks[index])
                room -= cost
                continue
            }
            if room >= minTrimmedExcerptTokens,
               let trimmed = await trimmedBlock(excerpts[index], fullCost: cost, toFit: room, countTokens: countTokens) {
                keptBlocks.append(trimmed)
                lastTrimmed = true
            }
            break
        }

        let excerptSection = keptBlocks.isEmpty
            ? noExcerptsNote
            : excerptsOpening + keptBlocks.joined() + excerptsClosing
        let prompt = assemble(
            systemPrompt: systemPrompt,
            exchanges: keptExchanges,
            excerptSection: excerptSection,
            question: question
        )
        return Result(
            prompt: prompt,
            includedExcerptCount: keptBlocks.count,
            lastExcerptTrimmed: lastTrimmed,
            includedHistoryCount: keptExchanges.count * 2
        )
    }

    private static func assemble(
        systemPrompt: String,
        exchanges: [Exchange],
        excerptSection: String,
        question: String
    ) -> String {
        var prompt = "<start_of_turn>user\n\(systemPrompt)\n"
        for (i, exchange) in exchanges.enumerated() {
            // The system prompt already opened the first user turn.
            prompt += i == 0 ? "\n" : "<start_of_turn>user\n"
            prompt += "\(exchange.user)<end_of_turn>\n<start_of_turn>model\n\(exchange.model)<end_of_turn>\n"
        }
        if !exchanges.isEmpty {
            prompt += "<start_of_turn>user\n"
        }
        prompt += excerptSection
        prompt += "\nUser question: \(question)<end_of_turn>\n<start_of_turn>model\n"
        return prompt
    }

    private static func exchangeText(_ exchange: Exchange) -> String {
        "<start_of_turn>user\n\(exchange.user)<end_of_turn>\n<start_of_turn>model\n\(exchange.model)<end_of_turn>\n"
    }

    private static func excerptBlock(header: String, text: String) -> String {
        "\(header)\n\(text)\n\n"
    }

    /// Pairs history into answered exchanges: system messages are skipped,
    /// back-to-back messages from one side are merged, a leading model reply
    /// is dropped, and so is a trailing unanswered user message.
    private static func exchanges(from history: [ChatMessage]) -> [Exchange] {
        var result: [Exchange] = []
        var pendingUser: String?
        var pendingModel: String?
        for message in history {
            switch message.role {
            case .user:
                if let user = pendingUser, let model = pendingModel {
                    result.append(Exchange(user: user, model: model))
                    pendingUser = nil
                    pendingModel = nil
                }
                pendingUser = [pendingUser, message.content].compactMap { $0 }.joined(separator: "\n\n")
            case .assistant:
                guard pendingUser != nil else { continue }
                pendingModel = [pendingModel, message.content].compactMap { $0 }.joined(separator: "\n\n")
            case .system:
                continue
            }
        }
        if let user = pendingUser, let model = pendingModel {
            result.append(Exchange(user: user, model: model))
        }
        return result
    }

    /// Cuts an excerpt's text at a word boundary so its block fits `limit`
    /// tokens, marking the cut. Nil if nothing useful fits.
    private static func trimmedBlock(
        _ excerpt: Excerpt,
        fullCost: Int,
        toFit limit: Int,
        countTokens: @Sendable ([String]) async -> [Int]
    ) async -> String? {
        // Start from the proportional estimate, then shrink until it fits.
        var targetChars = excerpt.text.count * limit / max(fullCost, 1)
        for _ in 0..<8 {
            var cut = excerpt.text.prefix(targetChars)
            if let lastSpace = cut.lastIndex(where: \.isWhitespace) {
                cut = cut[..<lastSpace]
            }
            guard !cut.isEmpty else { return nil }
            let block = excerptBlock(header: excerpt.header, text: String(cut) + trimMarker)
            if let cost = await countTokens([block]).first, cost <= limit {
                return block
            }
            targetChars = targetChars * 85 / 100
        }
        return nil
    }
}
