import SwiftUI

struct BookListRow: View {
    @Environment(AppState.self) private var appState
    let book: Book

    var body: some View {
        HStack(spacing: 12) {
            // Format badge
            Text(book.format.displayName)
                .font(.caption2)
                .fontWeight(.bold)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(formatColor.opacity(0.15))
                .foregroundStyle(formatColor)
                .clipShape(RoundedRectangle(cornerRadius: 4))

            // Title and author
            VStack(alignment: .leading, spacing: 2) {
                Text(book.displayTitle)
                    .font(.body)
                    .lineLimit(1)

                if let author = book.author {
                    Text(author)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            // File size
            Text(ByteCountFormatter.string(fromByteCount: book.fileSize, countStyle: .file))
                .font(.caption)
                .foregroundStyle(.secondary)

            // Availability indicator
            if !book.isAvailable {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                    .font(.caption)
            }
        }
        .padding(.vertical, 4)
        .contextMenu {
            if case .collection(let collectionId) = appState.sidebarSelection {
                Button("Remove from Collection", role: .destructive) {
                    Task { await appState.removeBookFromCollection(bookId: book.id, collectionId: collectionId) }
                }
                Divider()
            }

            if !appState.collections.isEmpty {
                Menu("Add to Collection") {
                    ForEach(appState.collections) { collection in
                        Button(collection.name) {
                            Task { await appState.addBooksToCollection(bookIDs: [book.id], collectionId: collection.id) }
                        }
                    }
                }
            }

            Divider()

            Button("Delete from Library", role: .destructive) {
                Task { await appState.deleteBook(book) }
            }
        }
    }

    private var formatColor: Color {
        switch book.format {
        case .pdf: .red
        case .epub: .blue
        case .fb2: .green
        case .mobi: .orange
        case .azw3: .purple
        case .chm: .teal
        }
    }
}
