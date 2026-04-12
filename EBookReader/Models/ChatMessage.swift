import Foundation

/// A single message in a chat conversation.
struct ChatMessage: Identifiable, Sendable {
    let id: UUID
    let role: Role
    var content: String
    let timestamp: Date
    var references: [BookReference]
    var isStreaming: Bool

    init(
        id: UUID = UUID(),
        role: Role,
        content: String,
        timestamp: Date = Date(),
        references: [BookReference] = [],
        isStreaming: Bool = false
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.references = references
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
}
