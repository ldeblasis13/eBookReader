import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 300)
        } detail: {
            VStack(spacing: 0) {
                // Tab bar is always visible when tabs are open
                if !appState.openTabs.isEmpty {
                    tabBar
                    Divider()
                }

                // Content: library or reader
                if let activeTab = appState.activeTab,
                   let book = appState.books.first(where: { $0.id == activeTab.bookID }) {
                    BookReaderView(book: book)
                        .id(activeTab.id)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    LibraryView()
                }
            }
        }
        .frame(minWidth: 800, minHeight: 500)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers: providers)
            return true
        }
        .overlay {
            if appState.repository == nil {
                ProgressView("Loading library...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.background)
            }
        }
    }

    // MARK: - Tab Bar

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                TabBarButton(
                    title: "Library",
                    systemImage: "books.vertical",
                    isActive: appState.activeTabID == nil,
                    showClose: false
                ) {
                    appState.switchToLibrary()
                }

                ForEach(appState.openTabs) { tab in
                    TabBarButton(
                        title: tab.bookTitle,
                        systemImage: "book",
                        isActive: appState.activeTabID == tab.id,
                        showClose: true
                    ) {
                        appState.activateTab(tab.id)
                    } onClose: {
                        appState.closeTab(tab.id)
                    }
                }
            }
            .padding(.horizontal, 4)
        }
        .frame(height: 32)
        .background(.bar)
    }

    // MARK: - Drop handling

    private func handleDrop(providers: [NSItemProvider]) {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: "public.file-url") { data, _ in
                guard let data = data as? Data,
                      let urlString = String(data: data, encoding: .utf8),
                      let url = URL(string: urlString) else { return }

                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return }

                Task { @MainActor in
                    if isDirectory.boolValue {
                        await appState.addFolder(url: url)
                    } else if FileTypeDetector.isSupportedBookFile(url) {
                        await appState.addBooks(urls: [url])
                    }
                }
            }
        }
    }
}

// MARK: - Tab Bar Button

private struct TabBarButton: View {
    let title: String
    let systemImage: String
    let isActive: Bool
    let showClose: Bool
    let onSelect: () -> Void
    var onClose: (() -> Void)? = nil

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.caption2)

            Text(title)
                .lineLimit(1)
                .font(.caption)

            if showClose {
                Button {
                    onClose?()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(isHovered || isActive ? 1 : 0)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(isActive ? Color.accentColor.opacity(0.2) : (isHovered ? Color.gray.opacity(0.1) : Color.clear))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
        .onHover { isHovered = $0 }
    }
}
