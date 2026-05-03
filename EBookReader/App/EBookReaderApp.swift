import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - App Delegate

/// Intercepts the quit event so LLM / Metal resources can be freed before
/// exit() runs.
///
/// The naive approach — listening to `willTerminateNotification` and
/// scheduling `Task { await llmEngine.shutdown() }` — is fire-and-forget:
/// AppKit does not wait for the Task, exit() runs immediately, C++ static
/// destructors tear down ggml Metal globals while resource sets are still
/// alive, and ggml_abort fires.
///
/// The correct fix is `applicationShouldTerminate` returning `.terminateLater`,
/// which suspends AppKit's quit path until we call
/// `NSApp.reply(toApplicationShouldTerminate: true)` — which AppState does at
/// the very end of `shutdownForTermination()`, after llama_backend_free().
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Injected by EBookReaderApp once appState is created.
    weak var appState: AppState?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let appState else { return .terminateNow }
        // Kick off the async shutdown; NSApp.reply is called inside
        // AppState.shutdownForTermination() once Metal resources are freed.
        Task {
            await appState.shutdownForTermination()
        }
        return .terminateLater
    }
}

// MARK: - App Entry Point

@main
struct EBookReaderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var appState = AppState()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
                .task {
                    // Wire the delegate before any background work starts.
                    appDelegate.appState = appState
                    await appState.start()
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
