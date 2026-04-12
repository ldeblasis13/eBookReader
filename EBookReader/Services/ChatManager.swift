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

    // MARK: - System Prompt

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
    You are a cookbook assistant searching the user's personal cookbook library. \
    The excerpts below are from their cookbooks. \
    STRICT RULES: \
    1. ONLY use recipes and information from the provided excerpts. Do NOT invent recipes. \
    2. For EACH recipe found, present it in this exact format: \
       RECIPE: [Recipe Name] \
       BOOK: [Book Title] \
       INGREDIENTS: [list all ingredients with quantities, one per line] \
       PREP TIME: [if mentioned] \
       COOK TIME: [if mentioned] \
       INSTRUCTIONS: [brief summary of key steps] \
    3. Number each recipe clearly (1., 2., 3., etc.) \
    4. If the user asks for a specific number of recipes, try to find that many. \
    5. If the user mentions ingredients they have, find recipes that use those ingredients. \
    6. If you can't find enough recipes, say how many you found and suggest broadening the search. \
    7. Never invent recipes not found in the excerpts.
    """

    // MARK: - Send Message

    /// Processes a user message: retrieves relevant context, generates a response.
    /// Returns the assistant message with book references.
    var debugInfo: String?

    func setDebugInfo(_ info: String?) {
        debugInfo = info
    }

    func sendMessage(
        _ text: String,
        books: [Book],
        history: [ChatMessage],
        currentBook: Book? = nil,
        isCookbookMode: Bool = false
    ) async -> ChatMessage {
        // Check if this is a book summarization request about the current book
        if let book = currentBook, isSummarizationQuery(text) {
            return await summarizeBook(book)
        }

        // Step 1: Search the library for relevant content
        // If there's a current book and the query seems book-specific, prioritize it
        var searchResults = await hybridSearchManager.search(query: text, books: books)

        // If we got few results from library-wide search, and a book is open,
        // also search specifically within the current book
        if let book = currentBook, searchResults.count < 3 {
            let bookOnly = await hybridSearchManager.search(query: text, books: [book])
            // Merge, dedup by bookId, keep highest scores
            var seen = Set(searchResults.map(\.bookId))
            for r in bookOnly where !seen.contains(r.bookId) {
                searchResults.append(r)
                seen.insert(r.bookId)
            }
        }

        let topResults = Array(searchResults.prefix(maxContextChunks))

        // Step 2: Build the prompt with context
        let prompt = buildPrompt(userQuery: text, context: topResults, history: history, isCookbookMode: isCookbookMode)

        // Step 3: Generate response
        let responseText: String
        do {
            responseText = try await llmEngine.generate(prompt: prompt, maxTokens: maxResponseTokens)
        } catch {
            logger.error("Generation failed: \(error)")
            let extra = debugInfo ?? "no additional info"
            responseText = "Unable to generate: \(error.localizedDescription). Debug: \(extra)"
        }

        // Step 4: Build book references from the context chunks used
        let references = topResults.compactMap { result -> ChatMessage.BookReference? in
            // Only include references that have meaningful snippets
            guard !result.snippet.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            return ChatMessage.BookReference(
                bookId: result.bookId,
                bookTitle: result.title,
                author: result.author,
                snippet: String(result.snippet.prefix(150)),
                position: result.position,
                isRecipe: isCookbookMode
            )
        }

        // Deduplicate references by bookId (keep first/highest-scored per book)
        var seenBooks = Set<UUID>()
        let uniqueReferences = references.filter { ref in
            if seenBooks.contains(ref.bookId) { return false }
            seenBooks.insert(ref.bookId)
            return true
        }

        return ChatMessage(
            role: .assistant,
            content: responseText,
            references: Array(uniqueReferences.prefix(5))
        )
    }

    // MARK: - Prompt Building

    private func buildPrompt(
        userQuery: String,
        context: [HybridSearchManager.HybridSearchResult],
        history: [ChatMessage],
        isCookbookMode: Bool = false
    ) -> String {
        let systemPrompt = isCookbookMode ? cookbookSystemPrompt : librarySystemPrompt
        var prompt = "<start_of_turn>user\n\(systemPrompt)\n"

        // Add context excerpts
        if !context.isEmpty {
            prompt += "\nBEGIN BOOK EXCERPTS (this is the ONLY information you may use to answer):\n\n"
            for (i, result) in context.enumerated() {
                let source = result.author != nil
                    ? "\(result.title) by \(result.author!)"
                    : result.title
                prompt += "--- Excerpt [\(i + 1)] from \"\(source)\" ---\n"
                prompt += "\(result.snippet)\n\n"
            }
            prompt += "END BOOK EXCERPTS\n"
        } else {
            prompt += "\nNo relevant excerpts were found in the user's book library.\n"
        }

        // Add recent conversation history (last 4 exchanges)
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

        // Add current query
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

    /// Summarizes an entire book using map-reduce: batch-summarize chunks, then combine.
    private func summarizeBook(_ book: Book) async -> ChatMessage {
        logger.info("Starting map-reduce summarization for: \(book.displayTitle)")

        // Load all text chunks for this book
        let chunks: [TextChunk]
        do {
            chunks = try await chunkRepository.fetchChunks(forBook: book.id)
        } catch {
            return ChatMessage(role: .assistant, content: "Couldn't load text for \"\(book.displayTitle)\". Make sure the book has been indexed.")
        }

        guard !chunks.isEmpty else {
            return ChatMessage(role: .assistant, content: "No indexed text found for \"\(book.displayTitle)\". The book may still be indexing.")
        }

        // Phase 1: Map — summarize batches of chunks
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

        // Phase 2: Reduce — combine batch summaries into final summary
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
            // Fall back to concatenated batch summaries
            finalSummary = "Summary of \"\(book.displayTitle)\":\n\n" + batchSummaries.joined(separator: "\n\n")
        }

        let reference = ChatMessage.BookReference(
            bookId: book.id,
            bookTitle: book.displayTitle,
            author: book.author,
            snippet: "Full book summary (\(chunks.count) sections analyzed)",
            position: nil
        )

        return ChatMessage(
            role: .assistant,
            content: finalSummary,
            references: [reference]
        )
    }

    /// Groups chunks into batches that fit within the context window.
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
