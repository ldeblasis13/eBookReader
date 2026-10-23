import Foundation
import GRDB

struct WatchedFolder: Identifiable, Codable, Sendable, Hashable {
    var id: UUID
    var path: String
    var bookmarkData: Data
    var dateAdded: Date
    var isFullImport: Bool
    /// Set for folders watched before deleted books were remembered
    /// (ExcludedBookFile). Their first reconcile treats files that have no
    /// book row as deleted instead of importing them; see
    /// `BookRepository.seedExclusions(forFolder:paths:)`.
    var needsExclusionSeed: Bool

    init(
        id: UUID = UUID(),
        path: String,
        bookmarkData: Data,
        dateAdded: Date = Date(),
        isFullImport: Bool = true,
        needsExclusionSeed: Bool = false
    ) {
        self.id = id
        self.path = path
        self.bookmarkData = bookmarkData
        self.dateAdded = dateAdded
        self.isFullImport = isFullImport
        self.needsExclusionSeed = needsExclusionSeed
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
        case id, path, bookmarkData, dateAdded, isFullImport, needsExclusionSeed
    }
}
