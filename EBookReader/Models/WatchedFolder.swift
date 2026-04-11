import Foundation
import GRDB

struct WatchedFolder: Identifiable, Codable, Sendable, Hashable {
    var id: UUID
    var path: String
    var bookmarkData: Data
    var dateAdded: Date
    var isFullImport: Bool

    init(
        id: UUID = UUID(),
        path: String,
        bookmarkData: Data,
        dateAdded: Date = Date(),
        isFullImport: Bool = true
    ) {
        self.id = id
        self.path = path
        self.bookmarkData = bookmarkData
        self.dateAdded = dateAdded
        self.isFullImport = isFullImport
    }

    var displayName: String {
        URL(fileURLWithPath: path).lastPathComponent
    }

    /// Resolves the security-scoped bookmark and returns the URL.
    /// Caller must call `url.stopAccessingSecurityScopedResource()` when done.
    func resolveBookmark() -> URL? {
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmarkData,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            return nil
        }

        if isStale {
            // Bookmark needs refreshing — caller should update bookmarkData
            return url
        }

        return url
    }
}

// MARK: - GRDB Conformance

extension WatchedFolder: FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "watchedFolder"

    enum Columns: String, ColumnExpression {
        case id, path, bookmarkData, dateAdded, isFullImport
    }
}
