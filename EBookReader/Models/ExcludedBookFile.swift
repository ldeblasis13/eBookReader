import Foundation
import GRDB

/// A book file the user deleted from the library while it stayed on disk.
///
/// Watched folders are reconciled with disk (at launch, on folder events,
/// on rescans), and without this record a deleted book would simply be
/// imported again. Its path is kept until the user explicitly adds the
/// file or its folder again, or removes the folder. If the file is renamed
/// or moved, the record follows it the same way a book row would.
struct ExcludedBookFile: Codable, Sendable, Hashable {
    var path: String
    var fileSize: Int64
    var dateExcluded: Date

    init(path: String, fileSize: Int64, dateExcluded: Date = Date()) {
        self.path = path
        self.fileSize = fileSize
        self.dateExcluded = dateExcluded
    }
}

// MARK: - GRDB Conformance

extension ExcludedBookFile: FetchableRecord, PersistableRecord {
    static let databaseTableName = "excludedBookFile"

    enum Columns: String, ColumnExpression {
        case path, fileSize, dateExcluded
    }
}
