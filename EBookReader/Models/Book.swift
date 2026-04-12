import Foundation
import GRDB

struct Book: Identifiable, Codable, Sendable, Hashable {
    var id: UUID
    var filePath: String
    var fileName: String
    var title: String?
    var author: String?
    var format: BookFormat
    var fileSize: Int64
    var pageCount: Int?
    var language: String?
    var publisher: String?
    var isbn: String?
    var bookDescription: String?
    /// Cover images are stored on-disk in ~/Library/Caches/EBookReader/Thumbnails/{id}.jpg.
    /// This flag records whether a cached thumbnail exists so the grid can optimise
    /// placeholder presentation without hitting the filesystem.
    var hasCachedThumbnail: Bool
    var bookmarkData: Data?
    var dateAdded: Date
    var dateLastOpened: Date?
    var lastReadPosition: String?
    var fullTextIndexed: Bool
    var embeddingIndexed: Bool

    init(
        id: UUID = UUID(),
        filePath: String,
        fileName: String,
        title: String? = nil,
        author: String? = nil,
        format: BookFormat,
        fileSize: Int64,
        pageCount: Int? = nil,
        language: String? = nil,
        publisher: String? = nil,
        isbn: String? = nil,
        bookDescription: String? = nil,
        hasCachedThumbnail: Bool = false,
        bookmarkData: Data? = nil,
        dateAdded: Date = Date(),
        dateLastOpened: Date? = nil,
        lastReadPosition: String? = nil,
        fullTextIndexed: Bool = false,
        embeddingIndexed: Bool = false
    ) {
        self.id = id
        self.filePath = filePath
        self.fileName = fileName
        self.title = title
        self.author = author
        self.format = format
        self.fileSize = fileSize
        self.pageCount = pageCount
        self.language = language
        self.publisher = publisher
        self.isbn = isbn
        self.bookDescription = bookDescription
        self.hasCachedThumbnail = hasCachedThumbnail
        self.bookmarkData = bookmarkData
        self.dateAdded = dateAdded
        self.dateLastOpened = dateLastOpened
        self.lastReadPosition = lastReadPosition
        self.fullTextIndexed = fullTextIndexed
        self.embeddingIndexed = embeddingIndexed
    }

    var displayTitle: String {
        title ?? fileName
    }

    var fileURL: URL {
        URL(fileURLWithPath: filePath)
    }

    var isAvailable: Bool {
        FileManager.default.fileExists(atPath: filePath)
    }

    /// Resolves this book's per-file security-scoped bookmark (used for individually imported books).
    func resolveFileBookmark() -> URL? {
        guard let bookmarkData else { return nil }
        var isStale = false
        return try? URL(
            resolvingBookmarkData: bookmarkData,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
    }
}

// MARK: - GRDB Conformance

extension Book: FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "book"

    enum Columns: String, ColumnExpression {
        case id, filePath, fileName, title, author, format, fileSize
        case pageCount, language, publisher, isbn, bookDescription
        case hasCachedThumbnail, bookmarkData, dateAdded, dateLastOpened
        case lastReadPosition, fullTextIndexed, embeddingIndexed
    }
}
