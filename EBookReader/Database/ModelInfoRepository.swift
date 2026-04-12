import Foundation
import GRDB

/// GRDB repository for ML model download/status tracking.
actor ModelInfoRepository {
    let dbPool: DatabasePool

    init(dbPool: DatabasePool) {
        self.dbPool = dbPool
    }

    func fetchAll() throws -> [ModelInfo] {
        try dbPool.read { db in
            try ModelInfo.fetchAll(db)
        }
    }

    func fetch(id: String) throws -> ModelInfo? {
        try dbPool.read { db in
            try ModelInfo.fetchOne(db, key: id)
        }
    }

    func insertIfMissing(_ model: ModelInfo) throws {
        try dbPool.write { db in
            if try ModelInfo.fetchOne(db, key: model.id) == nil {
                try model.insert(db)
            }
        }
    }

    func updateStatus(id: String, status: ModelStatus) throws {
        try dbPool.write { db in
            try db.execute(
                sql: "UPDATE modelInfo SET status = ? WHERE id = ?",
                arguments: [status.rawValue, id]
            )
        }
    }

    func updateDownloadProgress(id: String, bytes: Int64) throws {
        try dbPool.write { db in
            try db.execute(
                sql: "UPDATE modelInfo SET downloadedBytes = ? WHERE id = ?",
                arguments: [bytes, id]
            )
        }
    }

    func markReady(id: String, localPath: String) throws {
        try dbPool.write { db in
            try db.execute(
                sql: """
                UPDATE modelInfo SET status = 'ready', localPath = ?,
                dateDownloaded = ?, downloadedBytes = expectedSizeBytes
                WHERE id = ?
                """,
                arguments: [localPath, Date(), id]
            )
        }
    }
}
