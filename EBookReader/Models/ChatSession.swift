import Foundation

/// Observable chat session state. Holds the conversation history and input state.
@Observable @MainActor
class ChatSession {
    var messages: [ChatMessage] = []
    var inputText: String = ""
    var isGenerating: Bool = false

    func appendUserMessage(_ text: String) {
        let message = ChatMessage(role: .user, content: text)
        messages.append(message)
    }

    func appendAssistantMessage(_ text: String, references: [ChatMessage.BookReference] = []) {
        let message = ChatMessage(role: .assistant, content: text, references: references)
        messages.append(message)
    }

    func clear() {
        messages.removeAll()
        inputText = ""
        isGenerating = false
    }
}
