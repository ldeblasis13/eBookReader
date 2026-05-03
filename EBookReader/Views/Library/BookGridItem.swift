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
        // Drag carries the multi-selection if this book is part of one,
        // otherwise just this book. The autoclosure re-evaluates at drag
        // start so a selection change between mount and drag is honored.
        .draggable(BookDragPayload.encode(book: book.id, selection: appState.selectedBookIDs))
        // Modifier-aware taps. Most-specific gestures must come first or
        // the plain TapGesture swallows them.
        .gesture(TapGesture(count: 2).onEnded {
            appState.openBook(book)
        })
        .gesture(TapGesture(count: 1).modifiers(.command).onEnded {
            // Cmd-click toggles this book in/out of the selection.
            if appState.selectedBookIDs.contains(book.id) {
                appState.selectedBookIDs.remove(book.id)
            } else {
                appState.selectedBookIDs.insert(book.id)
            }
        })
        .gesture(TapGesture(count: 1).modifiers(.shift).onEnded {
            // Shift-click extends the selection. We don't know the visible
            // ordering from this view, so fall back to additive behavior;
            // LibraryView could host a true range-select in the future.
            appState.selectedBookIDs.insert(book.id)
        })
        .gesture(TapGesture(count: 1).onEnded {
            appState.selectedBookIDs = [book.id]
        })
        .task {
            thumbnailImage = await appState.loadThumbnail(for: book)
        }
        .contextMenu {
            // If the right-clicked book is part of an existing multi-
            // selection, the menu acts on the whole selection. Otherwise
            // it's a single-book menu (and the unrelated selection is
            // ignored — matches Finder behavior).
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
