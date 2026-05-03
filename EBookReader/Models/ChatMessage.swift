import Foundation

/// A single message in a chat conversation.
struct ChatMessage: Identifiable, Sendable {
    let id: UUID
    let role: Role
    var content: String
    let timestamp: Date
    var references: [BookReference]
    /// Structured recipe cards parsed from the LLM output (cookbook mode).
    /// When this is non-empty, the chat UI renders one card per recipe in
    /// place of the raw text bubble — `content` is kept as a fallback for
    /// debugging / accessibility.
    var recipes: [ParsedRecipe]
    var isStreaming: Bool

    init(
        id: UUID = UUID(),
        role: Role,
        content: String,
        timestamp: Date = Date(),
        references: [BookReference] = [],
        recipes: [ParsedRecipe] = [],
        isStreaming: Bool = false
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.references = references
        self.recipes = recipes
        self.isStreaming = isStreaming
    }

    enum Role: String, Sendable {
        case user
        case assistant
        case system
    }

    /// A reference to a specific location in a book, shown as a clickable card.
    struct BookReference: Identifiable, Sendable {
        let id: UUID
        let bookId: UUID
        let bookTitle: String
        let author: String?
        let snippet: String
        let position: ContentPosition?
        let isRecipe: Bool

        init(
            id: UUID = UUID(),
            bookId: UUID,
            bookTitle: String,
            author: String? = nil,
            snippet: String,
            position: ContentPosition? = nil,
            isRecipe: Bool = false
        ) {
            self.id = id
            self.bookId = bookId
            self.bookTitle = bookTitle
            self.author = author
            self.snippet = snippet
            self.position = position
            self.isRecipe = isRecipe
        }
    }

    /// A recipe extracted from the LLM's response, ready for card rendering.
    /// Built by the cookbook prompt parser in ChatManager.
    struct ParsedRecipe: Identifiable, Sendable {
        let id: UUID
        /// Recipe name as it appears in the source.
        let title: String
        /// Optional intro paragraph (shown above ingredients in the card).
        let preamble: String?
        /// Ingredient lines, already split out of the bullet list.
        let ingredients: [String]
        /// Free-form instructions block. May be a paragraph or numbered steps.
        let instructions: String
        /// Source book title.
        let bookTitle: String
        /// Source book id (for the Open action).
        let bookId: UUID
        /// Author of the source book, if known.
        let author: String?
        /// Position of the originating chunk so Open can jump to the page.
        let position: ContentPosition?
        /// Optional notes / yield / serving info pulled from the excerpt.
        let notes: String?
        /// LLM's self-reported completeness assessment ("complete recipe" / "partial recipe").
        let completeness: String?

        init(
            id: UUID = UUID(),
            title: String,
            preamble: String? = nil,
            ingredients: [String],
            instructions: String,
            bookTitle: String,
            bookId: UUID,
            author: String? = nil,
            position: ContentPosition? = nil,
            notes: String? = nil,
            completeness: String? = nil
        ) {
            self.id = id
            self.title = title
            self.preamble = preamble
            self.ingredients = ingredients
            self.instructions = instructions
            self.bookTitle = bookTitle
            self.bookId = bookId
            self.author = author
            self.position = position
            self.notes = notes
            self.completeness = completeness
        }
    }
}
