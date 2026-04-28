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
                // Surface real corpus state so the user can see WHY nothing matched
                // (zero embedded chunks vs zero recipe-like text vs unlucky query).
                let bookIds = Set(books.map(\.id))
                let totalChunks = (try? await chunkRepository.countChunks(forBookIds: bookIds)) ?? 0
                let embeddedChunks = (try? await chunkRepository.countEmbeddedChunks(forBookIds: bookIds)) ?? 0
                if totalChunks == 0 {
                    noResultsMsg = "No indexed text yet for your \(books.count) cookbook(s). Indexing may still be in progress — give it a minute and try again."
                } else if embeddedChunks == 0 {
                    noResultsMsg = "Your \(books.count) cookbook(s) have \(totalChunks) text chunks but none are embedded yet. Wait for embedding to finish, then try again."
                } else {
                    noResultsMsg = "No matches in your cookbook collection (\(books.count) books, \(totalChunks) chunks, \(embeddedChunks) embedded). Try a different ingredient name, a cuisine, or a dish name."
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

        // Step 2: Build prompt with FULL chunk text (never truncated) and stable IDs.
        let prompt = buildPrompt(userQuery: text, context: topResults, history: history, isCookbookMode: isCookbookMode)

        // Step 3: Generate response. Cookbook mode uses low temperature (extraction task).
        let temperature: Float = isCookbookMode ? 0.1 : 0.7
        let topP: Float = isCookbookMode ? 0.5 : 0.9

        let responseText: String
        do {
            responseText = try await llmEngine.generate(
                prompt: prompt,
                maxTokens: maxResponseTokens,
                temperature: temperature,
                topP: topP
            )
        } catch {
            logger.error("Generation failed: \(error)")
            let extra = debugInfo ?? "no additional info"
            responseText = "Unable to generate: \(error.localizedDescription). Debug: \(extra)"
        }

        // Step 4: Build references.
        // Cookbook mode: keep ALL chunk references (multiple recipes from same book OK).
        // General mode: dedupe by book.
        let references: [ChatMessage.BookReference]
        if isCookbookMode {
            references = topResults.compactMap { result in
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
            references = topResults.compactMap { result in
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

        return ChatMessage(
            role: .assistant,
            content: responseText,
            references: Array(references.prefix(isCookbookMode ? 10 : 5))
        )
    }

    // MARK: - Diagnostics

    private func logCookbookCorpusStats(books: [Book]) async {
        let bookIds = Set(books.map(\.id))
        let totalChunks = (try? await chunkRepository.countChunks(forBookIds: bookIds)) ?? 0
        let embeddedChunks = (try? await chunkRepository.countEmbeddedChunks(forBookIds: bookIds)) ?? 0
        let recipeHints = (try? await dbReadRecipeHintCount(forBookIds: bookIds)) ?? 0
        logger.info("Cookbook corpus: \(books.count) books, \(totalChunks) chunks, \(embeddedChunks) embedded, \(recipeHints) recipe hints")
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
    private func buildPrompt(
        userQuery: String,
        context: [HybridSearchManager.HybridSearchResult],
        history: [ChatMessage],
        isCookbookMode: Bool = false
    ) -> String {
        let systemPrompt = isCookbookMode ? cookbookSystemPrompt : librarySystemPrompt
        var prompt = "<start_of_turn>user\n\(systemPrompt)\n"

        if !context.isEmpty {
            prompt += "\nBEGIN BOOK EXCERPTS (this is the ONLY information you may use to answer):\n\n"
            for (i, result) in context.enumerated() {
                let titleEsc = result.title.replacingOccurrences(of: "\"", with: "\\\"")
                let chunkIdStr = result.chunkId.map(String.init) ?? "n/a"
                let recipeMark = result.isRecipeHit ? " | recipe-hint" : ""
                let header = isCookbookMode
                    ? "[excerpt \(i + 1) | \"\(titleEsc)\" | id=\(chunkIdStr)\(recipeMark)]"
                    : "--- Excerpt [\(i + 1)] from \"\(titleEsc)\" ---"
                prompt += "\(header)\n"
                prompt += "\(result.fullText)\n\n"  // FULL TEXT, NEVER TRUNCATED
            }
            prompt += "END BOOK EXCERPTS\n"
        } else {
            prompt += "\nNo relevant excerpts were found in the user's book library.\n"
        }

        // Conversation history (skip in cookbook mode — extraction is stateless).
        if !isCookbookMode {
            let recentHistory = history.suffix(8)
            for msg in recentHistory {
                switch msg.role {
                case .user:
                    prompt += "<end_of_turn>\n<start_of_turn>user\n\(msg.content)<end_of_turn>\n"
                case .assistant:
                    prompt += "<start_of_turn>model\n\(msg.content)<end_of_turn>\n"
                case .system:
                    break
                }
            }
        }

        prompt += "\nUser question: \(userQuery)<end_of_turn>\n<start_of_turn>model\n"
        return prompt
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
