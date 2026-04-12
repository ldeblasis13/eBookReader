import SwiftUI

/// Contextual toolbar shown when reading a book.
struct ReaderToolbar: View {
    @Environment(AppState.self) private var appState
    let book: Book
    let currentPage: Int
    let totalPages: Int
    @Binding var showTOC: Bool
    @Binding var showSearch: Bool
    @Binding var readerViewMode: ReaderViewMode
    let hasTOC: Bool
    var pageLabel: String = "Page"
    /// For ePub: current chapter/total chapters for prev/next buttons (nil = hide buttons)
    var chapterNav: (current: Int, total: Int)?
    var onChapterChange: ((Int) -> Void)?

    @State private var isEditingPage = false
    @State private var pageInputText = ""

    var body: some View {
        HStack(spacing: 12) {
            // TOC toggle
            if hasTOC {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showTOC.toggle()
                    }
                } label: {
                    Image(systemName: "sidebar.left")
                }
                .help("Table of Contents")
            }

            // Prev/Next chapter for ePub
            if let nav = chapterNav {
                HStack(spacing: 2) {
                    Button {
                        onChapterChange?(nav.current - 1)
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11))
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(nav.current <= 0)
                    .help("Previous chapter")

                    Text("\(nav.current + 1)/\(nav.total)")
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 30)

                    Button {
                        onChapterChange?(nav.current + 1)
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11))
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(nav.current >= nav.total - 1)
                    .help("Next chapter")
                }
                .padding(.horizontal, 2)
                .background(.quaternary.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }

            Spacer()

            // Page/Chapter indicator — clickable to jump to page
            if totalPages > 0 {
                if isEditingPage {
                    HStack(spacing: 4) {
                        Text("\(pageLabel)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("", text: $pageInputText)
                            .textFieldStyle(.roundedBorder)
                            .font(.caption)
                            .monospacedDigit()
                            .frame(width: 44)
                            .multilineTextAlignment(.center)
                            .onSubmit {
                                if let num = Int(pageInputText), num >= 1, num <= totalPages {
                                    NotificationCenter.default.post(
                                        name: .ebookReaderGoToPage,
                                        object: num - 1
                                    )
                                }
                                isEditingPage = false
                            }
                            .onExitCommand {
                                isEditingPage = false
                            }
                        Text("of \(totalPages)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                } else {
                    Button {
                        pageInputText = "\(currentPage + 1)"
                        isEditingPage = true
                    } label: {
                        HStack(spacing: 2) {
                            Text("\(pageLabel) \(currentPage + 1) of \(totalPages)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 7))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.quaternary.opacity(0.5))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)
                    .help("Click to jump to a page")
                }
            }

            Spacer()

            // Theme picker — colored circles
            HStack(spacing: 4) {
                ForEach(ReaderTheme.allCases, id: \.self) { theme in
                    Button {
                        appState.readerTheme = theme
                        appState.persistSettings()
                    } label: {
                        Circle()
                            .fill(theme.swatchColor)
                            .frame(width: 16, height: 16)
                            .overlay(
                                Circle().stroke(
                                    appState.readerTheme == theme ? Color.accentColor : Color.gray.opacity(0.4),
                                    lineWidth: appState.readerTheme == theme ? 2 : 0.5
                                )
                            )
                    }
                    .buttonStyle(.plain)
                    .help(theme.displayName)
                }
            }
            .help("Theme (⇧⌘T)")

            // Font size controls (reflowable only) / zoom label (PDF)
            if book.format != .pdf {
                HStack(spacing: 0) {
                    Button {
                        appState.decreaseFontSize()
                    } label: {
                        Text("A")
                            .font(.system(size: 10))
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(appState.readerFontSize <= 10)
                    .help("Decrease font size (⌘-)")

                    Divider().frame(height: 14)

                    Button {
                        appState.increaseFontSize()
                    } label: {
                        Text("A")
                            .font(.system(size: 14))
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(appState.readerFontSize >= 36)
                    .help("Increase font size (⌘+)")
                }
                .padding(.horizontal, 2)
                .background(.quaternary.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }

            // View mode picker — icon only
            HStack(spacing: 2) {
                ForEach(ReaderViewMode.allCases, id: \.self) { mode in
                    Button {
                        readerViewMode = mode
                    } label: {
                        Image(systemName: mode.systemImage)
                            .font(.system(size: 12))
                            .frame(width: 26, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(readerViewMode == mode ? Color.accentColor.opacity(0.2) : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .help(mode.rawValue)
                }
            }
            .padding(2)
            .background(.quaternary.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 6))

            // Search toggle
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showSearch.toggle()
                }
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .help("Search in book (⌘F)")

            // Format indicator
            Text(book.format.displayName)
                .font(.caption2)
                .fontWeight(.semibold)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.quaternary)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
        .onChange(of: currentPage) { _, _ in
            isEditingPage = false
        }
    }
}
