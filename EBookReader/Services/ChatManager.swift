import Foundation
import GRDB
import os

/// Orchestrates the RAG chat pipeline: user query → retrieve context → generate response.
actor ChatManager {
    private let hybridSearchManager: HybridSearchManager
    private let llmEngine: LLMEngine
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "EBookReader",
        category: "ChatManager"
    )

    private let maxContextChunks = 8
    private let maxResponseTokens = 1024

    init(hybridSearchManager: HybridSearchManager, llmEngine: LLMEngine) {
        self.hybridSearchManager = hybridSearchManager
        self.llmEngine = llmEngine
    }

    // MARK: - System Prompt

    private let systemPrompt = """
    You are an intelligent librarian assistant embedded in an ebook reader application. \
    You help users find information across their book library. \
    When answering questions, you MUST base your answers on the provided book excerpts. \
    For each piece of information you use, cite the source book by title. \
    If the excerpts don't contain relevant information, say so honestly. \
    Be concise but thorough. Format your answers clearly with paragraphs.
    """

    // MARK: - Send Message

    /// Processes a user message: retrieves relevant context, generates a response.
    /// Returns the assistant message with book references.
    func sendMessage(
        _ text: String,
        books: [Book],
        history: [ChatMessage]
    ) async -> ChatMessage {
        // Step 1: Retrieve relevant context via hybrid search
        let searchResults = await hybridSearchManager.search(query: text, books: books)
        let topResults = Array(searchResults.prefix(maxContextChunks))

        // Step 2: Build the prompt with context
        let prompt = buildPrompt(userQuery: text, context: topResults, history: history)

        // Step 3: Generate response
        let responseText: String
        do {
            responseText = try await llmEngine.generate(prompt: prompt, maxTokens: maxResponseTokens)
        } catch {
            logger.error("Generation failed: \(error)")
            responseText = "I'm sorry, I wasn't able to generate a response. The language model may still be loading. Please try again in a moment."
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
                position: result.position
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
        history: [ChatMessage]
    ) -> String {
        var prompt = "<|system|>\n\(systemPrompt)\n\n"

        // Add context excerpts
        if !context.isEmpty {
            prompt += "Here are relevant excerpts from the user's book library:\n\n"
            for (i, result) in context.enumerated() {
                let source = result.author != nil
                    ? "\(result.title) by \(result.author!)"
                    : result.title
                prompt += "[\(i + 1)] From \"\(source)\":\n"
                prompt += "\(result.snippet)\n\n"
            }
        }

        // Add recent conversation history (last 4 exchanges)
        let recentHistory = history.suffix(8)
        for msg in recentHistory {
            switch msg.role {
            case .user:
                prompt += "<|user|>\n\(msg.content)\n"
            case .assistant:
                prompt += "<|assistant|>\n\(msg.content)\n"
            case .system:
                break
            }
        }

        // Add current query
        prompt += "<|user|>\n\(userQuery)\n<|assistant|>\n"

        return prompt
    }
}
