import Foundation
import PDFKit
import os

actor MetadataExtractor {
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "EBookReader",
        category: "MetadataExtractor"
    )

    private let epubParser = EPubParser()
    private let fb2Parser = FB2Parser()
    private let mobiParser = MobiParser()
    private let chmParser = CHMParser()

    struct BookMetadata: Sendable {
        var title: String?
        var author: String?
        var pageCount: Int?
        var language: String?
        var publisher: String?
        var isbn: String?
        var description: String?
        var coverImageData: Data?
    }

    func extractMetadata(from url: URL, format: BookFormat) async -> BookMetadata {
        switch format {
        case .pdf:
            return extractPDFMetadata(from: url)
        case .epub:
            return await extractEPubMetadata(from: url)
        case .fb2:
            return await extractFB2Metadata(from: url)
        case .mobi, .azw3:
            return await extractMobiMetadata(from: url)
        case .chm:
            return await extractCHMMetadata(from: url)
        }
    }

    // MARK: - PDF

    private func extractPDFMetadata(from url: URL) -> BookMetadata {
        guard let document = PDFDocument(url: url) else {
            logger.warning("Failed to open PDF: \(url.lastPathComponent)")
            return BookMetadata()
        }

        var metadata = BookMetadata()
        let attributes = document.documentAttributes

        metadata.title = attributes?[PDFDocumentAttribute.titleAttribute] as? String
        metadata.author = attributes?[PDFDocumentAttribute.authorAttribute] as? String
        metadata.pageCount = document.pageCount

        if let firstPage = document.page(at: 0) {
            let thumbnailSize = CGSize(
                width: Constants.Thumbnail.width * 2,
                height: Constants.Thumbnail.height * 2
            )
            let thumbnail = firstPage.thumbnail(of: thumbnailSize, for: .mediaBox)
            metadata.coverImageData = jpegData(from: thumbnail)
        }

        return metadata
    }

    // MARK: - ePub

    private func extractEPubMetadata(from url: URL) async -> BookMetadata {
        // Use a temporary UUID for extraction during metadata scan
        let tempID = UUID()
        do {
            let content = try await epubParser.parse(bookURL: url, bookID: tempID)
            var metadata = BookMetadata()
            metadata.title = content.metadata.title
            metadata.author = content.metadata.author
            metadata.language = content.metadata.language
            metadata.publisher = content.metadata.publisher
            metadata.description = content.metadata.description
            metadata.pageCount = content.spine.count // chapters as "pages"

            if let coverData = await epubParser.extractCoverImage(from: content) {
                metadata.coverImageData = coverData
            }

            // Clean up temp extraction
            await epubParser.clearCache(bookID: tempID)
            return metadata
        } catch {
            logger.warning("Failed to parse ePub metadata: \(error.localizedDescription)")
            await epubParser.clearCache(bookID: tempID)
            return BookMetadata()
        }
    }

    // MARK: - FB2

    private func extractFB2Metadata(from url: URL) async -> BookMetadata {
        do {
            let content = try await fb2Parser.parse(bookURL: url)
            var metadata = BookMetadata()
            metadata.title = content.metadata.title
            metadata.author = content.metadata.author
            metadata.language = content.metadata.language
            metadata.description = content.metadata.annotation
            metadata.coverImageData = content.metadata.coverImageData
            return metadata
        } catch {
            logger.warning("Failed to parse FB2 metadata: \(error.localizedDescription)")
            return BookMetadata()
        }
    }

    // MARK: - Mobi / AZW3

    private func extractMobiMetadata(from url: URL) async -> BookMetadata {
        let meta = await mobiParser.extractMetadata(from: url)
        var metadata = BookMetadata()
        metadata.title = meta.title
        metadata.author = meta.author
        metadata.language = meta.language
        metadata.publisher = meta.publisher
        metadata.description = meta.description
        metadata.isbn = meta.isbn
        metadata.coverImageData = await mobiParser.extractCoverImage(from: url)
        return metadata
    }

    // MARK: - CHM

    private func extractCHMMetadata(from url: URL) async -> BookMetadata {
        let meta = await chmParser.extractMetadata(from: url)
        var metadata = BookMetadata()
        metadata.title = meta.title
        metadata.language = meta.language

        // CHM parser returns cover via full parse
        do {
            let content = try await chmParser.parse(bookURL: url)
            metadata.coverImageData = content.coverImageData
        } catch {
            logger.warning("Failed to extract CHM cover: \(error.localizedDescription)")
        }
        return metadata
    }

    // MARK: - Helpers

    private func jpegData(from image: NSImage) -> Data? {
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else {
            return nil
        }
        return bitmap.representation(
            using: .jpeg,
            properties: [.compressionFactor: Constants.Thumbnail.jpegQuality]
        )
    }
}
