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
        // Same multi-selection-aware drag as BookGridItem so list-mode
        // users can drop books on a sidebar collection too.
        .draggable(BookDragPayload.encode(book: book.id, selection: appState.selectedBookIDs))
        .contextMenu {
            // Mirror BookGridItem: when this row is part of an existing
            // multi-selection, the menu acts on the whole selection.
            let targetIds: [UUID] = {
                if appState.selectedBookIDs.contains(book.id) && appState.selectedBookIDs.count > 1 {
                    return Array(appState.selectedBookIDs)
                }
                return [book.id]
            }()
            let isMulti = targetIds.count > 1

            if case .collection(let collectionId) = appState.sidebarSelection {
                Button(isMulti
                    ? "Remove \(targetIds.count) Books from Collection"
                    : "Remove from Collection",
                       role: .destructive
                ) {
                    Task {
                        for id in targetIds {
                            await appState.removeBookFromCollection(bookId: id, collectionId: collectionId)
                        }
                    }
                }
                Divider()
            }

            if !appState.collections.isEmpty {
                Menu(isMulti
                    ? "Add \(targetIds.count) Books to Collection"
                    : "Add to Collection"
                ) {
                    ForEach(appState.collections) { collection in
                        Button(collection.name) {
                            Task {
                                await appState.addBooksToCollection(
                                    bookIDs: targetIds,
                                    collectionId: collection.id
                                )
                            }
                        }
                    }
                }
            }

            Divider()

            Button(isMulti
                ? "Delete \(targetIds.count) Books from Library"
                : "Delete from Library",
                   role: .destructive
            ) {
                Task {
                    if isMulti {
                        await appState.deleteBooks(Set(targetIds))
                    } else {
                        await appState.deleteBook(book)
                    }
                }
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
