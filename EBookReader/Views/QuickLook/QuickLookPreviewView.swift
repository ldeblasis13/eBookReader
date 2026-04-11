import PDFKit
import SwiftUI

/// Floating Quick Look-style preview panel for a book, shown over the library.
struct QuickLookPreviewView: View {
    @Environment(AppState.self) private var appState
    let book: Book
    let onDismiss: () -> Void
    let onOpen: () -> Void
    let onPrevious: () -> Void
    let onNext: () -> Void

    @State private var previewImage: NSImage?
    @State private var textExcerpt: String?
    @State private var isLoading = true

    var body: some View {
        ZStack {
            // Dimmed backdrop — click to dismiss
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture { onDismiss() }

            // Panel
            VStack(spacing: 0) {
                header
                Divider()
                content
                Divider()
                footer
            }
            .frame(width: 620, height: 480)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.3), radius: 20, y: 8)
        }
        .transition(.opacity.combined(with: .scale(scale: 0.95)))
        .id(book.id) // reset state when book changes
        .task(id: book.id) {
            isLoading = true
            previewImage = nil
            textExcerpt = nil
            await loadPreview()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: formatIcon)
                .foregroundStyle(formatColor)
                .font(.title3)

            VStack(alignment: .leading, spacing: 1) {
                Text(book.displayTitle)
                    .font(.headline)
                    .lineLimit(1)

                if let author = book.author {
                    Text(author)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Content

    private var content: some View {
        HStack(alignment: .top, spacing: 20) {
            // Preview image
            previewImagePanel
                .frame(width: 220)

            // Metadata + excerpt
            VStack(alignment: .leading, spacing: 0) {
                metadataSection
                    .padding(.bottom, 12)

                if let excerpt = effectiveExcerpt, !excerpt.isEmpty {
                    Divider()
                        .padding(.bottom, 8)
                    excerptSection(excerpt)
                }

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .frame(maxHeight: .infinity)
    }

    // MARK: - Preview Image

    @ViewBuilder
    private var previewImagePanel: some View {
        if isLoading {
            RoundedRectangle(cornerRadius: 6)
                .fill(.quaternary)
                .frame(maxHeight: .infinity)
                .overlay { ProgressView() }
        } else if let image = previewImage {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
        } else {
            placeholderCover
        }
    }

    private var placeholderCover: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(
                LinearGradient(
                    colors: placeholderColors,
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .frame(maxHeight: .infinity)
            .overlay {
                VStack(spacing: 8) {
                    Image(systemName: formatIcon)
                        .font(.system(size: 36))
                        .foregroundStyle(.white.opacity(0.7))
                    Text(book.format.displayName)
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundStyle(.white.opacity(0.8))
                }
            }
    }

    // MARK: - Metadata

    private var metadataSection: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
            metadataRow("Format", value: book.format.displayName)
            metadataRow("Size", value: ByteCountFormatter.string(
                fromByteCount: book.fileSize, countStyle: .file
            ))
            if let pages = book.pageCount {
                metadataRow("Pages", value: "\(pages)")
            }
            if let language = book.language {
                metadataRow("Language", value: language)
            }
            if let publisher = book.publisher {
                metadataRow("Publisher", value: publisher)
            }
            if let isbn = book.isbn {
                metadataRow("ISBN", value: isbn)
            }
        }
    }

    private func metadataRow(_ label: String, value: String) -> some View {
        GridRow {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            Text(value)
                .font(.caption)
                .lineLimit(1)
                .gridColumnAlignment(.leading)
        }
    }

    // MARK: - Excerpt

    private var effectiveExcerpt: String? {
        textExcerpt ?? book.bookDescription
    }

    private func excerptSection(_ text: String) -> some View {
        ScrollView {
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            HStack(spacing: 4) {
                Button(action: onPrevious) {
                    Image(systemName: "chevron.left")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.leftArrow, modifiers: [])

                Button(action: onNext) {
                    Image(systemName: "chevron.right")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.rightArrow, modifiers: [])
            }

            Spacer()

            if !book.isAvailable {
                Label("File not found", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.yellow)
            }

            Button("Open") {
                onOpen()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Loading

    private func loadPreview() async {
        _ = appState.ensureFileAccess(for: book)

        // Load preview image
        switch book.format {
        case .pdf:
            previewImage = await renderPDFFirstPage()
        default:
            previewImage = await loadCoverImage()
        }

        // Load text excerpt for reflowable formats
        switch book.format {
        case .epub:
            textExcerpt = await extractEPubExcerpt()
        case .fb2:
            textExcerpt = await extractFB2Excerpt()
        case .mobi, .azw3:
            textExcerpt = await extractMobiExcerpt()
        case .chm:
            textExcerpt = await extractCHMExcerpt()
        default:
            break
        }

        isLoading = false
    }

    /// Render the first page of a PDF at high quality for Quick Look.
    private func renderPDFFirstPage() async -> NSImage? {
        let url = book.fileURL
        guard let document = PDFDocument(url: url),
              let page = document.page(at: 0) else {
            return await loadCoverImage()
        }
        // Render at 2x for Retina, fitting within ~440x600pt
        let pageBounds = page.bounds(for: .mediaBox)
        let scale = min(440.0 / pageBounds.width, 600.0 / pageBounds.height) * 2
        let size = CGSize(
            width: pageBounds.width * scale,
            height: pageBounds.height * scale
        )
        return page.thumbnail(of: size, for: .mediaBox)
    }

    /// Load cover image from the file-based thumbnail cache via ThumbnailGenerator.
    private func loadCoverImage() async -> NSImage? {
        await appState.loadThumbnail(for: book)
    }

    /// Extract a brief text excerpt from the first ePub chapter.
    private func extractEPubExcerpt() async -> String? {
        let parser = EPubParser()
        guard let content = try? await parser.parse(bookURL: book.fileURL, bookID: book.id),
              let firstSpine = content.spine.first else { return nil }
        let chapterURL = content.opfDirectoryURL.appendingPathComponent(firstSpine.href)
        guard let data = try? Data(contentsOf: chapterURL),
              let html = String(data: data, encoding: .utf8) else { return nil }
        let stripped = Self.stripHTML(html)
        return stripped.isEmpty ? nil : String(stripped.prefix(800))
    }

    /// Extract description or first-section text from FB2.
    private func extractFB2Excerpt() async -> String? {
        // Prefer description from metadata (already in DB)
        if let desc = book.bookDescription, !desc.isEmpty { return desc }

        let parser = FB2Parser()
        guard let content = try? await parser.parse(bookURL: book.fileURL) else { return nil }
        if let annotation = content.metadata.annotation, !annotation.isEmpty {
            return String(annotation.prefix(800))
        }
        // Fall back to stripping first section HTML
        let stripped = Self.stripHTML(content.htmlContent)
        return stripped.isEmpty ? nil : String(stripped.prefix(800))
    }

    /// Extract a brief text excerpt from a Mobi/AZW3 book.
    private func extractMobiExcerpt() async -> String? {
        if let desc = book.bookDescription, !desc.isEmpty { return desc }

        let parser = MobiParser()
        guard let content = try? await parser.parse(bookURL: book.fileURL) else { return nil }
        if let desc = content.metadata.description, !desc.isEmpty {
            return String(desc.prefix(800))
        }
        let stripped = Self.stripHTML(content.htmlContent)
        return stripped.isEmpty ? nil : String(stripped.prefix(800))
    }

    /// Extract a brief text excerpt from a CHM book.
    private func extractCHMExcerpt() async -> String? {
        if let desc = book.bookDescription, !desc.isEmpty { return desc }

        let parser = CHMParser()
        guard let content = try? await parser.parse(bookURL: book.fileURL) else { return nil }
        let stripped = Self.stripHTML(content.htmlContent)
        return stripped.isEmpty ? nil : String(stripped.prefix(800))
    }

    /// Simple HTML tag stripper.
    static func stripHTML(_ html: String) -> String {
        html.replacingOccurrences(of: "<style[^>]*>[\\s\\S]*?</style>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "<script[^>]*>[\\s\\S]*?</script>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Format Helpers

    private var formatIcon: String {
        switch book.format {
        case .pdf: "doc.richtext"
        case .epub: "book"
        case .fb2: "doc.text"
        case .mobi: "book.closed"
        case .azw3: "book.closed.fill"
        case .chm: "questionmark.folder"
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

    private var placeholderColors: [Color] {
        [formatColor.opacity(0.7), formatColor.opacity(0.4)]
    }
}
