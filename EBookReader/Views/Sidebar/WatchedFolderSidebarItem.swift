import SwiftUI
import UniformTypeIdentifiers

struct WatchedFolderSidebarItem: View {
    @Environment(AppState.self) private var appState
    let folder: WatchedFolder

    private var bookCount: Int {
        let prefix = folder.path + "/"
        return appState.books.filter { $0.filePath.hasPrefix(prefix) }.count
    }

    var body: some View {
        Label(folder.displayName, systemImage: folder.isFullImport ? "folder.fill" : "folder")
            .foregroundStyle(folder.isFullImport ? .primary : .secondary)
            .badge(bookCount)
            .help(folder.path)
        .contextMenu {
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting(
                    [URL(fileURLWithPath: folder.path)]
                )
            }

            if !folder.isFullImport {
                Button("Add More Books...") {
                    openAddBooksPanel()
                }
            }

            Divider()

            Button("Remove", role: .destructive) {
                Task {
                    await appState.removeFolder(folder)
                }
            }
        }
    }

    private func openAddBooksPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: folder.path)
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
