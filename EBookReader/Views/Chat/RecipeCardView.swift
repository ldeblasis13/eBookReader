import SwiftUI

/// A styled recipe card shown in cookbook mode chat responses.
/// Displays recipe title, book source, ingredients, and prep/cook time.
struct RecipeCardView: View {
    let reference: ChatMessage.BookReference
    let onOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header: recipe icon + book info
            HStack(spacing: 8) {
                Image(systemName: "fork.knife")
                    .font(.title3)
                    .foregroundStyle(.orange)

                VStack(alignment: .leading, spacing: 2) {
                    Text(reference.bookTitle)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .lineLimit(2)
                    if let author = reference.author {
                        Text(author)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Button("Open") {
                    onOpen()
                }
                .font(.caption2)
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .tint(.orange)
            }

            Divider()

            // Snippet / excerpt
            Text(reference.snippet)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(4)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.orange.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.orange.opacity(0.2), lineWidth: 1)
        )
    }
}
