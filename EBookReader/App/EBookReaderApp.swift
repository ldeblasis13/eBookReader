import SwiftUI
import UniformTypeIdentifiers

@main
struct EBookReaderApp: App {
    @State private var appState = AppState()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
                .task {
                    await appState.start()
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    appState.prepareForTermination()
                    appState.persistSettings()
                    appState.stopAccessingFolders()
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {}

            // File menu
            CommandGroup(after: .newItem) {
                Button("Add Books...") {
                    openAddBooksPanel()
                }
                .keyboardShortcut("o", modifiers: .command)

                Button("Add Folder...") {
                    openAddFolderPanel()
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            }

            // Find in book (Cmd+F when a book tab is active)
            CommandGroup(replacing: .textEditing) {
                Button("Find in Book...") {
                    NotificationCenter.default.post(
                        name: .ebookReaderToggleFindBar,
                        object: nil
                    )
                }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(appState.activeTabID == nil)
            }

            // View / Appearance
            CommandMenu("Appearance") {
                Button("Cycle Theme") {
                    appState.cycleTheme()
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])

                Divider()

                Button("Increase Font Size") {
                    appState.increaseFontSize()
                }
                .keyboardShortcut("+", modifiers: .command)

                Button("Decrease Font Size") {
                    appState.decreaseFontSize()
                }
                .keyboardShortcut("-", modifiers: .command)
            }

            // Tab navigation
            CommandMenu("Tabs") {
                Button("Show Library") {
                    appState.switchToLibrary()
                }
                .keyboardShortcut("l", modifiers: .command)

                Divider()

                Button("Next Tab") {
                    appState.selectNextTab()
                }
                .keyboardShortcut("]", modifiers: [.command, .shift])

                Button("Previous Tab") {
                    appState.selectPreviousTab()
                }
                .keyboardShortcut("[", modifiers: [.command, .shift])

                Divider()

                Button("Close Tab") {
                    appState.closeActiveTab()
                }
                .keyboardShortcut("w", modifiers: .command)
                .disabled(appState.activeTabID == nil)
            }
        }

        Settings {
            SettingsView()
                .environment(appState)
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
