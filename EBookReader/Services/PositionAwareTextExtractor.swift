import Foundation
import PDFKit
import os

/// Extracts text from books with position metadata for each chunk.
/// Produces ~400-word chunks (within MiniLM's 512-token context window)
/// with ContentPosition indicating where in the book each chunk came from.
actor PositionAwareTextExtractor {
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "EBookReader",
        category: "PositionAwareTextExtractor"
    )

    struct PositionedChunk: Sendable {
        let text: String
        let chunkIndex: Int
        let position: ContentPosition
    }

    private let wordLimit = Constants.Models.chunkWordCount // ~400 words

    // MARK: - Public API

    func extractPositionedChunks(from book: Book) async -> [PositionedChunk] {
        let url = book.fileURL
        switch book.format {
        case .pdf:
            return extractPDFChunks(url: url)
        case .epub:
            return await extractEPubChunks(url: url, bookID: book.id)
        case .fb2:
            return extractFB2Chunks(url: url)
        case .mobi, .azw3:
            return await extractMobiChunks(url: url)
        case .chm:
            return await extractCHMChunks(url: url)
        }
    }

    // MARK: - PDF

    private func extractPDFChunks(url: URL) -> [PositionedChunk] {
        guard let document = PDFDocument(url: url) else { return [] }
        var chunks: [PositionedChunk] = []
        var currentText = ""
        var currentWordCount = 0
        var chunkStartPage = 0

        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            let pageText = page.string ?? ""
            let words = pageText.split(separator: " ", omittingEmptySubsequences: true)

            if currentText.isEmpty {
                chunkStartPage = pageIndex
            }

            for word in words {
                currentText += (currentText.isEmpty ? "" : " ") + word
                currentWordCount += 1

                if currentWordCount >= wordLimit {
                    chunks.append(PositionedChunk(
                        text: currentText.trimmingCharacters(in: .whitespacesAndNewlines),
                        chunkIndex: chunks.count,
                        position: .pdf(pageIndex: chunkStartPage)
                    ))
                    currentText = ""
                    currentWordCount = 0
                    chunkStartPage = pageIndex
                }
            }
        }

        if !currentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            chunks.append(PositionedChunk(
                text: currentText.trimmingCharacters(in: .whitespacesAndNewlines),
                chunkIndex: chunks.count,
                position: .pdf(pageIndex: chunkStartPage)
            ))
        }

        return chunks
    }

    // MARK: - ePub

    private func extractEPubChunks(url: URL, bookID: UUID) async -> [PositionedChunk] {
        let parser = EPubParser()
        guard let content = try? await parser.parse(bookURL: url, bookID: bookID) else { return [] }

        var chunks: [PositionedChunk] = []

        for (spineIndex, spineItem) in content.spine.enumerated() {
            let chapterURL = content.opfDirectoryURL.appendingPathComponent(spineItem.href)
            guard let data = try? Data(contentsOf: chapterURL),
                  let html = String(data: data, encoding: .utf8) else { continue }

            let text = stripHTML(html)
            let chapterChunks = chunkText(text, wordLimit: wordLimit)

            for chunkText in chapterChunks {
                chunks.append(PositionedChunk(
                    text: chunkText,
                    chunkIndex: chunks.count,
                    position: .epub(spineIndex: spineIndex, href: spineItem.href)
                ))
            }
        }

        return chunks
    }

    // MARK: - FB2

    private func extractFB2Chunks(url: URL) -> [PositionedChunk] {
        guard let data = try? Data(contentsOf: url),
              let document = try? XMLDocument(data: data) else { return [] }

        var chunks: [PositionedChunk] = []
        let sections = (try? document.nodes(forXPath: "//*[local-name()='body']/*[local-name()='section']")) ?? []

        for (sectionIndex, section) in sections.enumerated() {
            let text = section.stringValue ?? ""
            let sectionChunks = chunkText(text, wordLimit: wordLimit)

            for chunkText in sectionChunks {
                chunks.append(PositionedChunk(
                    text: chunkText,
                    chunkIndex: chunks.count,
                    position: .fb2(sectionIndex: sectionIndex)
                ))
            }
        }

        return chunks
    }

    // MARK: - Mobi/AZW3

    private func extractMobiChunks(url: URL) async -> [PositionedChunk] {
        let parser = MobiParser()
        guard let content = try? await parser.parse(bookURL: url) else { return [] }

        let text = stripHTML(content.htmlContent)
        let allChunks = chunkText(text, wordLimit: wordLimit)
        let total = max(allChunks.count, 1)

        return allChunks.enumerated().map { (i, chunkText) in
            PositionedChunk(
                text: chunkText,
                chunkIndex: i,
                position: .mobi(offsetFraction: Double(i) / Double(total))
            )
        }
    }

    // MARK: - CHM

    private func extractCHMChunks(url: URL) async -> [PositionedChunk] {
        let parser = CHMParser()
        guard let content = try? await parser.parse(bookURL: url) else { return [] }

        // CHM has a single htmlContent string; chunk with section path refs
        let text = stripHTML(content.htmlContent)
        let allChunks = chunkText(text, wordLimit: wordLimit)

        return allChunks.enumerated().map { (i, chunkText) in
            let path = content.sections.indices.contains(i)
                ? content.sections[i].path : (content.sections.first?.path ?? "")
            return PositionedChunk(
                text: chunkText,
                chunkIndex: i,
                position: .chm(fileIndex: i, fileName: path)
            )
        }
    }

    // MARK: - Utilities

    private func stripHTML(_ html: String) -> String {
        // Try XMLDocument for clean stripping
        if let doc = try? XMLDocument(xmlString: html, options: [.documentTidyHTML]),
           let text = doc.rootDocument?.rootElement()?.stringValue {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Fallback: regex
        return html
            .replacingOccurrences(of: "<style[^>]*>[\\s\\S]*?</style>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "<script[^>]*>[\\s\\S]*?</script>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func chunkText(_ text: String, wordLimit: Int) -> [String] {
        let words = text.split(separator: " ", omittingEmptySubsequences: true)
        guard !words.isEmpty else { return [] }

        var chunks: [String] = []
        var currentChunk: [Substring] = []

        for word in words {
            currentChunk.append(word)
            if currentChunk.count >= wordLimit {
                // Try to break at sentence boundary
                let joined = currentChunk.joined(separator: " ")
                if let lastSentenceEnd = joined.lastIndex(where: { ".!?".contains($0) }),
                   lastSentenceEnd > joined.index(joined.startIndex, offsetBy: joined.count / 2) {
                    let sentenceEnd = joined.index(after: lastSentenceEnd)
                    chunks.append(String(joined[..<sentenceEnd]).trimmingCharacters(in: .whitespacesAndNewlines))
                    let remainder = String(joined[sentenceEnd...]).trimmingCharacters(in: .whitespacesAndNewlines)
                    currentChunk = remainder.isEmpty ? [] : remainder.split(separator: " ")
                } else {
                    chunks.append(joined)
                    currentChunk = []
                }
            }
        }

        if !currentChunk.isEmpty {
            let joined = currentChunk.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty {
                chunks.append(joined)
            }
        }

        return chunks
    }
}
