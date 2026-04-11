import SwiftUI

struct BookGridItem: View {
    @Environment(AppState.self) private var appState
    let book: Book

    @State private var thumbnailImage: NSImage?
    @State private var isHovered = false

    private var isSelected: Bool {
        appState.selectedBookIDs.contains(book.id)
    }

    var body: some View {
        VStack(spacing: 8) {
            // Cover
            ZStack {
                if let image = thumbnailImage {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(
                            width: Constants.Library.gridItemMinWidth,
                            height: Constants.Thumbnail.height
                        )
                        .clipped()
                } else {
                    placeholderCover
                }
            }
            .frame(
                width: Constants.Library.gridItemMinWidth,
                height: Constants.Thumbnail.height
            )
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .shadow(color: .black.opacity(isHovered ? 0.3 : 0.15), radius: isHovered ? 8 : 4)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isSelected ? Color.accentColor : Color(nsColor: .separatorColor),
                            lineWidth: isSelected ? 2.5 : 0.5)
            )
            .overlay(alignment: .topTrailing) {
                if !book.isAvailable {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                        .padding(4)
                }
            }

            // Title and Author
            VStack(spacing: 2) {
                Text(book.displayTitle)
                    .font(.caption)
                    .fontWeight(.medium)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)

                if let author = book.author {
                    Text(author)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(width: Constants.Library.gridItemMinWidth)
        }
        .padding(.vertical, 4)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .draggable(book.id.uuidString)
        .onTapGesture(count: 2) {
            appState.openBook(book)
        }
        .onTapGesture(count: 1) {
            appState.selectedBookIDs = [book.id]
        }
        .task {
            thumbnailImage = await appState.loadThumbnail(for: book)
        }
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

    private var placeholderCover: some View {
        ZStack {
            LinearGradient(
                colors: placeholderColors,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            VStack(spacing: 4) {
                Text(book.format.displayName)
                    .font(.caption2)
                    .fontWeight(.bold)
                    .foregroundStyle(.white.opacity(0.7))

                Text(book.displayTitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
                    .padding(.horizontal, 8)
            }
        }
    }

    private var placeholderColors: [Color] {
        switch book.format {
        case .pdf: [.red.opacity(0.7), .red.opacity(0.4)]
        case .epub: [.blue.opacity(0.7), .blue.opacity(0.4)]
        case .fb2: [.green.opacity(0.7), .green.opacity(0.4)]
        case .mobi: [.orange.opacity(0.7), .orange.opacity(0.4)]
        case .azw3: [.purple.opacity(0.7), .purple.opacity(0.4)]
        case .chm: [.teal.opacity(0.7), .teal.opacity(0.4)]
        }
    }
}
