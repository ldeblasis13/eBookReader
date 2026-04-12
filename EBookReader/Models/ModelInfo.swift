import Foundation
import GRDB

/// Download/readiness status for a bundled ML model.
enum ModelStatus: String, Codable, Sendable {
    case pending
    case downloading
    case ready
    case error
}

/// Tracks a downloadable ML model (embedding or LLM).
struct ModelInfo: Identifiable, Codable, Sendable, Hashable {
    var id: String              // e.g. "embedding-minilm", "llm-gemma"
    var displayName: String
    var fileName: String
    var expectedSizeBytes: Int64
    var sha256: String?
    var downloadURL: String
    var localPath: String?
    var status: ModelStatus
    var downloadedBytes: Int64
    var dateDownloaded: Date?

    var isReady: Bool { status == .ready }
    var downloadFraction: Double {
        guard expectedSizeBytes > 0 else { return 0 }
        return Double(downloadedBytes) / Double(expectedSizeBytes)
    }
}

// MARK: - GRDB

extension ModelInfo: FetchableRecord, PersistableRecord {
    static let databaseTableName = "modelInfo"

    enum Columns: String, ColumnExpression {
        case id, displayName, fileName, expectedSizeBytes, sha256
        case downloadURL, localPath, status, downloadedBytes, dateDownloaded
    }
}
