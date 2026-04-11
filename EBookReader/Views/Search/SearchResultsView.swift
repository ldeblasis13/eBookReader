import SwiftUI

/// Displays full-text search results with snippets.
struct SearchResultsView: View {
    @Environment(AppState.self) private var appState
    let results: [FullTextSearchManager.SearchResult]

    var body: some View {
        List {
            ForEach(results) { result in
                SearchResultRow(result: result)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        if let book = appState.books.first(where: { $0.id == result.id }) {
                            appState.openBook(book)
                        }
                    }
            }
        }
        .listStyle(.inset)
    }
}

private struct SearchResultRow: View {
    let result: FullTextSearchManager.SearchResult

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(result.title)
                    .font(.headline)
                    .lineLimit(1)

                Spacer()

                Text(result.format.displayName)
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.quaternary)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }

            if let author = result.author {
                Text(author)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Text(highlightedSnippet(result.snippet))
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(3)
        }
        .padding(.vertical, 4)
    }

    @MainActor
    private func highlightedSnippet(_ snippet: String) -> AttributedString {
        // Build highlighted attributes via AttributeContainer to avoid synthesised
        // AttributeScopes key-path expressions that trigger Sendable warnings in
        // strict-concurrency mode (Apple SDK gap, not a real data-race).
        var highlightContainer = AttributeContainer()
        highlightContainer.font = .caption.bold()
        highlightContainer.foregroundColor = .primary

        var result = AttributedString()
        let parts = snippet.components(separatedBy: "**")
        for (index, part) in parts.enumerated() {
            var attr = AttributedString(part)
            if index % 2 == 1 {
                attr.mergeAttributes(highlightContainer)
            }
            result.append(attr)
        }
        return result
    }
}
