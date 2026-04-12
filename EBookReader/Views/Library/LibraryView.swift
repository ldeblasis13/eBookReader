import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @Environment(AppState.self) private var appState

    private var filteredBooks: [Book] {
        var result: [Book]

        // Filter by sidebar selection
        switch appState.sidebarSelection {
        case .recentlyOpened:
            result = appState.books
                .filter { $0.dateLastOpened != nil }
                .sorted { ($0.dateLastOpened ?? .distantPast) > ($1.dateLastOpened ?? .distantPast) }
        case .watchedFolder(let folderId):
            if let folder = appState.watchedFolders.first(where: { $0.id == folderId }) {
                let prefix = folder.path + "/"
                result = appState.books.filter { $0.filePath.hasPrefix(prefix) }
            } else {
                result = appState.books
            }
        case .collection:
            result = appState.books.filter { appState.collectionBookIDs.contains($0.id) }
        default:
            result = appState.books
        }

        if let filter = appState.formatFilter {
            result = result.filter { $0.format == filter }
        }

        if !appState.searchText.isEmpty {
            let query = appState.searchText.lowercased()
            result = result.filter { book in
                book.fileName.lowercased().contains(query) ||
                (book.title?.lowercased().contains(query) ?? false) ||
                (book.author?.lowercased().contains(query) ?? false)
            }
        }

        return result
    }

    var body: some View {
        @Bindable var state = appState

        Group {
            if !appState.ftsResults.isEmpty && !appState.searchText.isEmpty {
                SearchResultsView(results: appState.ftsResults)
            } else if filteredBooks.isEmpty && !appState.isScanning {
                if case .collection = appState.sidebarSelection {
                    collectionEmptyState
                } else if appState.books.isEmpty {
                    emptyState
                } else {
                    ContentUnavailableView.search
                }
            } else {
                switch appState.viewMode {
                case .grid:
                    gridView
                case .list:
                    listView
                }
            }
        }
        .searchable(text: $state.searchText, prompt: "Search books")
        .onChange(of: appState.searchText) { _, newValue in
            appState.debouncedSearch(query: newValue)
        }
        .toolbar {
            libraryToolbar
        }
        .overlay {
            let showProgress = appState.isScanning || appState.isIndexing
                || appState.isDownloadingModels || appState.isEmbeddingIndexing
            if showProgress {
                VStack {
                    Spacer()
                    HStack {
                        ProgressView()
                            .scaleEffect(0.7)
                        if appState.isScanning {
                            Text("Scanning...")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else if appState.isDownloadingModels, let dp = appState.modelDownloadProgress {
                            Text("Downloading \(dp.displayName)... \(Int(dp.fraction * 100))%")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else if appState.isIndexing {
                            let p = appState.indexingProgress
                            Text("Indexing \(p.done)/\(p.total)...")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else if appState.isEmbeddingIndexing {
                            let p = appState.embeddingIndexingProgress
                            Text("Embedding \(p.done)/\(p.total)...")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 12)
                }
            }
        }
        .overlay {
            if let bookId = appState.quickLookBookID,
               let book = filteredBooks.first(where: { $0.id == bookId }) {
                QuickLookPreviewView(
                    book: book,
                    onDismiss: {
                        withAnimation(.easeOut(duration: 0.15)) {
                            appState.quickLookBookID = nil
                        }
                    },
                    onOpen: {
                        appState.quickLookBookID = nil
                        appState.openBook(book)
                    },
                    onPrevious: { navigateQuickLook(direction: -1) },
                    onNext: { navigateQuickLook(direction: 1) }
                )
                .transition(.opacity)
            }
        }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.space) {
            toggleQuickLook()
        }
        .onKeyPress(.escape) {
            if appState.quickLookBookID != nil {
                withAnimation(.easeOut(duration: 0.15)) {
                    appState.quickLookBookID = nil
                }
                return .handled
            }
            return .ignored
        }
        .onKeyPress(.leftArrow) {
            guard appState.quickLookBookID != nil else { return .ignored }
            navigateQuickLook(direction: -1)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            guard appState.quickLookBookID != nil else { return .ignored }
            navigateQuickLook(direction: 1)
            return .handled
        }
    }

    // MARK: - Grid View

    private var gridView: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(
                    minimum: Constants.Library.gridItemMinWidth,
                    maximum: Constants.Library.gridItemMaxWidth
                ), spacing: Constants.Library.gridSpacing)],
                spacing: 20
            ) {
                ForEach(filteredBooks) { book in
                    BookGridItem(book: book)
                }
            }
            .padding()
        }
    }

    // MARK: - List View

    private var listView: some View {
        Table(filteredBooks, selection: Binding(
            get: { appState.selectedBookIDs },
            set: { appState.selectedBookIDs = $0 }
        )) {
            TableColumn("Title") { book in
                HStack(spacing: 4) {
                    Text(book.displayTitle)
                    if !book.isAvailable {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.yellow)
                            .font(.caption2)
                    }
                }
            }
            .width(min: 150, ideal: 250)

            TableColumn("Author") { book in
                Text(book.author ?? "Unknown")
                    .foregroundStyle(.secondary)
            }
            .width(min: 100, ideal: 150)

            TableColumn("Format") { book in
                Text(book.format.displayName)
            }
            .width(60)

            TableColumn("Size") { book in
                Text(ByteCountFormatter.string(fromByteCount: book.fileSize, countStyle: .file))
            }
            .width(80)

            TableColumn("Date Added") { book in
                Text(book.dateAdded, style: .date)
            }
            .width(100)
        }
        .contextMenu(forSelectionType: UUID.self) { selectedIDs in
            let selectedBooks = filteredBooks.filter { selectedIDs.contains($0.id) }
            if !selectedBooks.isEmpty {
                if case .collection(let collectionId) = appState.sidebarSelection {
                    Button("Remove from Collection", role: .destructive) {
                        Task {
                            for book in selectedBooks {
                                await appState.removeBookFromCollection(bookId: book.id, collectionId: collectionId)
                            }
                        }
                    }
                    Divider()
                }

                if !appState.collections.isEmpty {
                    Menu("Add to Collection") {
                        ForEach(appState.collections) { collection in
                            Button(collection.name) {
                                Task {
                                    await appState.addBooksToCollection(
                                        bookIDs: selectedBooks.map(\.id),
                                        collectionId: collection.id
                                    )
                                }
                            }
                        }
                    }
                }

                Divider()

                Button(selectedBooks.count == 1
                    ? "Delete from Library"
                    : "Delete \(selectedBooks.count) Books from Library",
                       role: .destructive
                ) {
                    Task { await appState.deleteBooks(Set(selectedBooks.map(\.id))) }
                }
            }
        } primaryAction: { selectedIDs in
            // Double-click opens the first selected book
            if let bookID = selectedIDs.first,
               let book = filteredBooks.first(where: { $0.id == bookID }) {
                appState.openBook(book)
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "books.vertical")
                .font(.system(size: 48))
                .foregroundStyle(.quaternary)

            Text("No Books Yet")
                .font(.title2)
                .foregroundStyle(.secondary)

            Text("Drag books or folders here, or use the buttons below")
                .font(.body)
                .foregroundStyle(.tertiary)

            HStack(spacing: 12) {
                Button("Add Books...") {
                    openAddBooksPanel()
                }
                .buttonStyle(.borderedProminent)

                Button("Add Folder...") {
                    openAddFolderPanel()
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var collectionEmptyState: some View {
        ContentUnavailableView(
            "No Books in Collection",
            systemImage: "folder.circle",
            description: Text("Drag books here or right-click a book to add it.")
        )
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var libraryToolbar: some ToolbarContent {
        ToolbarItemGroup {
            Picker("View", selection: Binding(
                get: { appState.viewMode },
                set: {
                    appState.viewMode = $0
                    appState.persistSettings()
                }
            )) {
                Image(systemName: "square.grid.2x2")
                    .tag(LibraryViewMode.grid)
                Image(systemName: "list.bullet")
                    .tag(LibraryViewMode.list)
            }
            .pickerStyle(.segmented)

            Menu {
                ForEach(SortOrder.allCases, id: \.self) { order in
                    Button {
                        if appState.sortOrder == order {
                            appState.sortAscending.toggle()
                        } else {
                            appState.sortOrder = order
                            appState.sortAscending = true
                        }
                        appState.persistSettingsAndResort()
                    } label: {
                        HStack {
                            Text(order.displayName)
                            if appState.sortOrder == order {
                                Image(systemName: appState.sortAscending ? "chevron.up" : "chevron.down")
                            }
                        }
                    }
                }
            } label: {
                Label("Sort", systemImage: "arrow.up.arrow.down")
            }

            Menu {
                Button("All Formats") {
                    appState.formatFilter = nil
                }
                Divider()
                ForEach(BookFormat.allCases, id: \.self) { format in
                    Button(format.displayName) {
                        appState.formatFilter = format
                    }
                }
            } label: {
                Label("Filter", systemImage: "line.3.horizontal.decrease.circle")
            }

        }
    }

    private func openAddFolderPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.message = "Choose folders containing e-books"

        if panel.runModal() == .OK {
            Task { @MainActor in
                for url in panel.urls {
                    await appState.addFolder(url: url)
                }
            }
        }
    }

    // MARK: - Quick Look

    private func toggleQuickLook() -> KeyPress.Result {
        guard let selectedId = appState.selectedBookIDs.first else { return .ignored }
        withAnimation(.easeOut(duration: 0.15)) {
            if appState.quickLookBookID == selectedId {
                appState.quickLookBookID = nil
            } else {
                appState.quickLookBookID = selectedId
            }
        }
        return .handled
    }

    private func navigateQuickLook(direction: Int) {
        let books = filteredBooks
        guard !books.isEmpty else { return }

        let currentId = appState.quickLookBookID ?? appState.selectedBookIDs.first
        guard let currentId,
              let currentIndex = books.firstIndex(where: { $0.id == currentId }) else {
            // No current selection — show first or last
            let book = direction > 0 ? books.first! : books.last!
            appState.selectedBookIDs = [book.id]
            appState.quickLookBookID = book.id
            return
        }

        let newIndex = currentIndex + direction
        guard newIndex >= 0, newIndex < books.count else { return }
        let book = books[newIndex]
        appState.selectedBookIDs = [book.id]
        appState.quickLookBookID = book.id
    }

    // MARK: - File Panels

    private func openAddBooksPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.message = "Choose e-book files to add"
        panel.allowedContentTypes = BookFormat.allCases.map { format in
            .init(filenameExtension: format.fileExtension) ?? .data
        }

        if panel.runModal() == .OK {
            Task { @MainActor in
                await appState.addBooks(urls: panel.urls)
            }
        }
    }
}
