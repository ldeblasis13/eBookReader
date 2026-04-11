import AppKit
import Foundation
import PDFKit
import os

actor ThumbnailGenerator {
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "EBookReader",
        category: "ThumbnailGenerator"
    )

    private let cache = NSCache<NSString, NSImage>()

    init() {
        cache.countLimit = 200
    }

    /// Returns a thumbnail for the book, using cache layers: memory → disk → generate.
    func thumbnail(for book: Book) async -> NSImage? {
        let cacheKey = book.id.uuidString as NSString

        // 1. Check memory cache
        if let cached = cache.object(forKey: cacheKey) {
            return cached
        }

        // 2. Check disk cache
        let diskPath = diskCachePath(for: book.id)
        if let diskImage = NSImage(contentsOf: diskPath) {
            cache.setObject(diskImage, forKey: cacheKey)
            return diskImage
        }

        // 3. Generate from book file
        guard let image = await generateThumbnail(for: book) else {
            return nil
        }

        // Save to caches
        cache.setObject(image, forKey: cacheKey)
        saveToDisk(image: image, bookId: book.id)

        return image
    }

    /// Saves raw cover image data for a book directly to the disk cache.
    /// Call this at import time so subsequent `thumbnail(for:)` calls are cache-hits.
    /// - Returns: `true` if the data was saved successfully.
    @discardableResult
    func saveCoverData(_ data: Data, for bookId: UUID) -> Bool {
        guard let image = NSImage(data: data) else { return false }
        let resizedImage = resized(image)
        saveToDisk(image: resizedImage, bookId: bookId)
        cache.setObject(resizedImage, forKey: bookId.uuidString as NSString)
        return true
    }

    /// Generates a thumbnail from the book file.
    private func generateThumbnail(for book: Book) async -> NSImage? {
        let url = book.fileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        switch book.format {
        case .pdf:
            return generatePDFThumbnail(from: url)
        case .mobi, .azw3:
            return await generateMobiThumbnail(from: url)
        case .chm:
            return await generateCHMThumbnail(from: url)
        case .epub, .fb2:
            // Covers are saved to disk at import time via saveCoverData(_:for:).
            // If the disk-cache file exists, thumbnail(for:) already returned it above.
            return nil
        }
    }

    private func generatePDFThumbnail(from url: URL) -> NSImage? {
        guard let document = PDFDocument(url: url),
              let firstPage = document.page(at: 0) else {
            return nil
        }

        let size = CGSize(
            width: Constants.Thumbnail.width * 2,
            height: Constants.Thumbnail.height * 2
        )
        return firstPage.thumbnail(of: size, for: .mediaBox)
    }

    private func generateMobiThumbnail(from url: URL) async -> NSImage? {
        let parser = MobiParser()
        guard let data = await parser.extractCoverImage(from: url),
              let image = NSImage(data: data) else { return nil }
        return resized(image)
    }

    private func generateCHMThumbnail(from url: URL) async -> NSImage? {
        let parser = CHMParser()
        guard let content = try? await parser.parse(bookURL: url),
              let data = content.coverImageData,
              let image = NSImage(data: data) else { return nil }
        return resized(image)
    }

    private func resized(_ image: NSImage) -> NSImage {
        let targetSize = NSSize(
            width: Constants.Thumbnail.width * 2,
            height: Constants.Thumbnail.height * 2
        )
        let newImage = NSImage(size: targetSize)
        newImage.lockFocus()
        image.draw(
            in: NSRect(origin: .zero, size: targetSize),
            from: NSRect(origin: .zero, size: image.size),
            operation: .copy,
            fraction: 1.0
        )
        newImage.unlockFocus()
        return newImage
    }

    // MARK: - Disk Cache

    private func diskCachePath(for bookId: UUID) -> URL {
        Constants.Directories.thumbnailCache
            .appendingPathComponent("\(bookId.uuidString).jpg")
    }

    private func saveToDisk(image: NSImage, bookId: UUID) {
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let jpegData = bitmap.representation(
                  using: .jpeg,
                  properties: [.compressionFactor: Constants.Thumbnail.jpegQuality]
              ) else {
            return
        }

        let path = diskCachePath(for: bookId)
        do {
            try FileManager.default.createDirectory(
                at: path.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try jpegData.write(to: path)
        } catch {
            logger.warning("Failed to cache thumbnail for \(bookId): \(error)")
        }
    }
}
