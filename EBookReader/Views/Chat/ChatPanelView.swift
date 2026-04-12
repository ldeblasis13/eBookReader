import SwiftUI

/// Right-side chat panel for AI-powered library search.
struct ChatPanelView: View {
    @Environment(AppState.self) private var appState
    @State private var scrollProxy: ScrollViewProxy?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            chatHeader
            Divider()

            // Messages
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if appState.chatSession.messages.isEmpty {
                            emptyState
                        }
                        ForEach(appState.chatSession.messages) { message in
                            ChatMessageView(message: message) { ref in
                                openBookReference(ref)
                            }
                            .id(message.id)
                        }

                        if appState.chatSession.isGenerating {
                            HStack(spacing: 6) {
                                ProgressView()
                                    .scaleEffect(0.6)
                                Text("Thinking...")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 16)
                            .id("generating")
                        }
                    }
                    .padding(.vertical, 12)
                }
                .onAppear { scrollProxy = proxy }
                .onChange(of: appState.chatSession.messages.count) {
                    if let last = appState.chatSession.messages.last {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }

            Divider()

            // Input
            chatInput
        }
        .frame(minWidth: 300, idealWidth: 380, maxWidth: 480)
        .background(.background)
    }

    // MARK: - Header

    private var chatHeader: some View {
        HStack {
            Image(systemName: appState.isCookbookModeActive ? "fork.knife" : "sparkles")
                .foregroundStyle(appState.isCookbookModeActive ? .orange : .blue)
            Text(appState.isCookbookModeActive ? "Cookbook Search" : "AI Chat")
                .font(.headline)
            Spacer()
            Button {
                appState.chatSession.clear()
            } label: {
                Image(systemName: "trash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Clear chat")
            .disabled(appState.chatSession.messages.isEmpty)

            Button {
                appState.showChatPanel = false
            } label: {
                Image(systemName: "xmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Close chat")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Input

    private var chatInput: some View {
        HStack(spacing: 8) {
            TextField(appState.isCookbookModeActive ? "Search recipes..." : "Ask about your books...", text: Binding(
                get: { appState.chatSession.inputText },
                set: { appState.chatSession.inputText = $0 }
            ), axis: .vertical)
            .textFieldStyle(.plain)
            .lineLimit(1...4)
            .onSubmit {
                sendMessage()
            }

            Button {
                sendMessage()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
                    .foregroundStyle(canSend ? .blue : .secondary)
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
        }
        .padding(12)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text("Ask anything about your books")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("I'll search your library and answer based on what's in your books.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .padding(.horizontal, 20)
    }

    // MARK: - Actions

    private var canSend: Bool {
        !appState.chatSession.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && !appState.chatSession.isGenerating
    }

    private func sendMessage() {
        let text = appState.chatSession.inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !appState.chatSession.isGenerating else { return }

        appState.chatSession.inputText = ""
        appState.chatSession.appendUserMessage(text)

        Task {
            await appState.sendChatMessage(text)
        }
    }

    private func openBookReference(_ ref: ChatMessage.BookReference) {
        guard let book = appState.books.first(where: { $0.id == ref.bookId }) else { return }
        appState.openBook(book)
        // TODO: Navigate to ref.position after book opens
    }
}

// MARK: - Message View

struct ChatMessageView: View {
    let message: ChatMessage
    let onOpenReference: (ChatMessage.BookReference) -> Void

    var body: some View {
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 6) {
            // Message bubble
            Text(message.content)
                .font(.body)
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(bubbleBackground)
                .clipShape(RoundedRectangle(cornerRadius: 12))

            // Book references (assistant only)
            if !message.references.isEmpty {
                let hasRecipes = message.references.contains(where: \.isRecipe)
                VStack(alignment: .leading, spacing: 6) {
                    Text(hasRecipes ? "From Your Cookbooks" : "Sources")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .textCase(.uppercase)

                    ForEach(message.references) { ref in
                        if ref.isRecipe {
                            RecipeCardView(reference: ref) {
                                onOpenReference(ref)
                            }
                        } else {
                            BookReferenceCard(reference: ref) {
                                onOpenReference(ref)
                            }
                        }
                    }
                }
                .padding(.horizontal, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
        .padding(.horizontal, 16)
    }

    private var bubbleBackground: some ShapeStyle {
        if message.role == .user {
            return AnyShapeStyle(Color.blue.opacity(0.2))
        } else {
            return AnyShapeStyle(Color.secondary.opacity(0.1))
        }
    }
}

// MARK: - Book Reference Card

struct BookReferenceCard: View {
    let reference: ChatMessage.BookReference
    let onOpen: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "book.closed")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 1) {
                Text(reference.bookTitle)
                    .font(.caption)
                    .fontWeight(.medium)
                    .lineLimit(1)
                if let author = reference.author {
                    Text(author)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Button("Open") {
                onOpen()
            }
            .font(.caption2)
            .buttonStyle(.bordered)
            .controlSize(.mini)
        }
        .padding(8)
        .background(Color.secondary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
