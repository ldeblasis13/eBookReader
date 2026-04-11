import Foundation
import PDFKit
import os

/// Extracts plain text from book files for FTS indexing.
/// Chunks output into ~5000-character segments.
actor TextExtractor {
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "EBookReader",
        category: "TextExtractor"
    )

    static let chunkSize = 5000

    // MARK: - Public API

    func extractChunks(from book: Book) async -> [String] {
        let url = book.fileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }

        let rawText: String
        switch book.format {
        case .pdf:
            rawText = extractPDFText(url: url)
        case .epub:
            rawText = await extractEPubText(url: url, bookID: book.id)
        case .fb2:
            rawText = extractFB2Text(url: url)
        case .mobi, .azw3:
            rawText = await extractMobiText(url: url)
        case .chm:
            rawText = await extractCHMText(url: url)
        }

        guard !rawText.isEmpty else { return [] }
        return chunkText(rawText)
    }

    // MARK: - PDF

    private func extractPDFText(url: URL) -> String {
        guard let document = PDFDocument(url: url) else { return "" }
        var text = ""
        text.reserveCapacity(document.pageCount * 500)
        for i in 0..<document.pageCount {
            if let page = document.page(at: i), let pageText = page.string {
                text += pageText
                text += "\n"
            }
        }
        return text
    }

    // MARK: - ePub

    private func extractEPubText(url: URL, bookID: UUID) async -> String {
        let parser = EPubParser()
        guard let content = try? await parser.parse(bookURL: url, bookID: bookID) else { return "" }

        var text = ""
        for spineItem in content.spine {
            let chapterURL = content.opfDirectoryURL.appendingPathComponent(spineItem.href)
            if let data = try? Data(contentsOf: chapterURL),
               let htmlString = String(data: data, encoding: .utf8) {
                text += stripHTML(htmlString)
                text += "\n"
            }
        }
        return text
    }

    // MARK: - FB2

    private func extractFB2Text(url: URL) -> String {
        guard let data = try? Data(contentsOf: url),
              let document = try? XMLDocument(data: data) else { return "" }

        let bodyNodes = (try? document.nodes(forXPath: "//*[local-name()='body']")) ?? []
        var text = ""
        for node in bodyNodes {
            if let str = node.stringValue {
                text += str
                text += "\n"
            }
        }
        return text
    }

    // MARK: - Mobi / AZW3

    private func extractMobiText(url: URL) async -> String {
        let parser = MobiParser()
        guard let content = try? await parser.parse(bookURL: url) else { return "" }
        return stripHTML(content.htmlContent)
    }

    // MARK: - CHM

    private func extractCHMText(url: URL) async -> String {
        let parser = CHMParser()
        guard let content = try? await parser.parse(bookURL: url) else { return "" }
        return stripHTML(content.htmlContent)
    }

    // MARK: - Helpers

    private func stripHTML(_ html: String) -> String {
        guard let data = html.data(using: .utf8),
              let doc = try? XMLDocument(data: data, options: [.documentTidyHTML]) else {
            // Fallback: regex strip
            return html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return doc.rootDocument?.rootElement()?.stringValue?
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func chunkText(_ text: String) -> [String] {
        var chunks: [String] = []
        var start = text.startIndex
        while start < text.endIndex {
            let end = text.index(start, offsetBy: Self.chunkSize, limitedBy: text.endIndex) ?? text.endIndex
            // Try to break at a word boundary
            var breakPoint = end
            if end < text.endIndex {
                if let spaceIndex = text[start..<end].lastIndex(of: " ") {
                    breakPoint = text.index(after: spaceIndex)
                }
            }
            let chunk = String(text[start..<breakPoint])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !chunk.isEmpty {
                chunks.append(chunk)
            }
            start = breakPoint
        }
        return chunks
    }
}
