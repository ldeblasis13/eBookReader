import SwiftUI
import UniformTypeIdentifiers

struct SidebarView: View {
    @Environment(AppState.self) private var appState
    @State private var isCreatingCollection = false
    @State private var isCreatingGroup = false
    @State private var newItemName = ""

    var body: some View {
        @Bindable var state = appState

        List(selection: $state.sidebarSelection) {
            Section("Library") {
                Label("All Books", systemImage: "books.vertical")
                    .badge(appState.books.count)
                    .tag(SidebarSelection.library)

                Label("Recently Opened", systemImage: "clock")
                    .badge(appState.books.filter { $0.dateLastOpened != nil }.count)
                    .tag(SidebarSelection.recentlyOpened)
            }

            Section("Sources") {
                ForEach(appState.watchedFolders) { folder in
                    WatchedFolderSidebarItem(folder: folder)
                        .tag(SidebarSelection.watchedFolder(folder.id))
                }
            }

            Section("Collections") {
                // Ungrouped collections
                ForEach(ungroupedCollections) { collection in
                    CollectionSidebarItem(collection: collection)
                        .tag(SidebarSelection.collection(collection.id))
                }

                // Collection groups with their collections
                ForEach(appState.collectionGroups) { group in
                    CollectionGroupSidebarItem(group: group)
                }

                // Inline new collection field
                if isCreatingCollection {
                    TextField("Collection name", text: $newItemName)
                        .onSubmit {
                            let name = newItemName.trimmingCharacters(in: .whitespaces)
                            if !name.isEmpty {
                                Task { await appState.createCollection(name: name) }
                            }
                            isCreatingCollection = false
                            newItemName = ""
                        }
                        .onExitCommand {
                            isCreatingCollection = false
                            newItemName = ""
                        }
                }

                if isCreatingGroup {
                    TextField("Group name", text: $newItemName)
                        .onSubmit {
                            let name = newItemName.trimmingCharacters(in: .whitespaces)
                            if !name.isEmpty {
                                Task { await appState.createCollectionGroup(name: name) }
                            }
                            isCreatingGroup = false
                            newItemName = ""
                        }
                        .onExitCommand {
                            isCreatingGroup = false
                            newItemName = ""
                        }
                }
            }
        }
        .listStyle(.sidebar)
        .toolbar {
            ToolbarItemGroup {
                Menu {
                    Button("Add Folder...") {
                        openAddFolderPanel()
                    }
                    Button("Add Books...") {
                        openAddBooksPanel()
                    }

                    Divider()

                    Button("New Collection") {
                        isCreatingGroup = false
                        isCreatingCollection = true
                        newItemName = ""
                    }
                    Button("New Collection Group") {
                        isCreatingCollection = false
                        isCreatingGroup = true
                        newItemName = ""
                    }
                } label: {
                    Label("Add", systemImage: "plus")
                }
            }
        }
        .onChange(of: appState.sidebarSelection) { _, newValue in
            if case .collection(let id) = newValue {
                Task { await appState.loadCollectionBooks(id) }
            }
        }
    }

    private var ungroupedCollections: [Collection] {
        appState.collections.filter { $0.collectionGroupId == nil }
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

// MARK: - Collection Sidebar Item

struct CollectionSidebarItem: View {
    @Environment(AppState.self) private var appState
    let collection: Collection
    @State private var isRenaming = false
    @State private var editedName = ""

    private var bookCount: Int {
        if case .collection(collection.id) = appState.sidebarSelection {
            return appState.collectionBookIDs.count
        }
        return 0
    }

    var body: some View {
        Group {
            if isRenaming {
                TextField("Name", text: $editedName)
                    .onSubmit { commitRename() }
                    .onExitCommand { isRenaming = false }
            } else {
                Label {
                    Text(collection.name)
                } icon: {
                    Image(systemName: collection.isCookbook ? "fork.knife.circle" : "folder.circle")
                }
            }
        }
        .dropDestination(for: String.self) { items, _ in
            // BookDragPayload handles both formats: plain UUIDs (legacy /
            // single-book drag) and "BOOKS:<csv>" (multi-selection drag).
            let bookIDs = BookDragPayload.decode(items: items)
            guard !bookIDs.isEmpty else { return false }
            Task { await appState.addBooksToCollection(bookIDs: bookIDs, collectionId: collection.id) }
            return true
        }
        .contextMenu {
            Button("Rename...") {
                editedName = collection.name
                isRenaming = true
            }

            if !appState.collectionGroups.isEmpty {
                Menu("Move to Group") {
                    if collection.collectionGroupId != nil {
                        Button("No Group") {
                            Task { await appState.moveCollectionToGroup(collectionId: collection.id, groupId: nil) }
                        }
                        Divider()
                    }
                    ForEach(appState.collectionGroups) { group in
                        if group.id != collection.collectionGroupId {
                            Button(group.name) {
                                Task { await appState.moveCollectionToGroup(collectionId: collection.id, groupId: group.id) }
                            }
                        }
                    }
                }
            }

            Divider()

            Button(collection.isCookbook ? "Mark as Regular Collection" : "Mark as Cookbook") {
                Task { await appState.toggleCookbookType(collectionId: collection.id) }
            }

            if collection.isCookbook {
                Button("Rebuild Index") {
                    Task { await appState.rebuildCookbookIndex(collectionId: collection.id) }
                }
            }

            Divider()

            Button("Delete", role: .destructive) {
                Task { await appState.deleteCollection(id: collection.id) }
            }
        }
    }

    private func commitRename() {
        let name = editedName.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty {
            Task { await appState.renameCollection(id: collection.id, name: name) }
        }
        isRenaming = false
    }
}

// MARK: - Collection Group Sidebar Item

struct CollectionGroupSidebarItem: View {
    @Environment(AppState.self) private var appState
    let group: CollectionGroup
    @State private var isRenaming = false
    @State private var editedName = ""

    private var groupCollections: [Collection] {
        appState.collections.filter { $0.collectionGroupId == group.id }
    }

    var body: some View {
        DisclosureGroup {
            ForEach(groupCollections) { collection in
                CollectionSidebarItem(collection: collection)
                    .tag(SidebarSelection.collection(collection.id))
            }
        } label: {
            if isRenaming {
                TextField("Name", text: $editedName)
                    .onSubmit { commitRename() }
                    .onExitCommand { isRenaming = false }
            } else {
                Label(group.name, systemImage: "folder.circle.fill")
            }
        }
        .contextMenu {
            Button("Rename...") {
                editedName = group.name
                isRenaming = true
            }

            Divider()

            Button("Delete Group", role: .destructive) {
                Task { await appState.deleteCollectionGroup(id: group.id) }
            }
        }
    }

    private func commitRename() {
        let name = editedName.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty {
            Task { await appState.renameCollectionGroup(id: group.id, name: name) }
        }
        isRenaming = false
    }
}
