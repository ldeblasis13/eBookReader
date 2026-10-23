import Foundation
import GRDB

/// A book file the user deleted from the library while it stayed on disk.
///
/// Watched folders are reconciled with disk (at launch, on folder events,
/// on rescans), and without this record a deleted book would simply be
/// imported again. It only holds back a file at the same path with the
/// same size, and it never stops a missing book from being relocated
/// there. It's dropped when that path is gone (removed, renamed or moved
/// away — a renamed deleted book may then be imported again), when the
/// user adds the file or its folder again, or when the folder is removed.
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
