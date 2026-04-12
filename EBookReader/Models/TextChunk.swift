import Foundation
import GRDB

/// A text chunk from a book with an optional embedding vector.
/// Chunks are ~400 words (within MiniLM's 512-token context window).
struct TextChunk: Identifiable, Codable, Sendable {
    var id: Int64?          // autoincrement rowid
    var bookId: UUID
    var chunkIndex: Int
    var text: String
    var positionJSON: String?
    var embedding: Data?    // 384 × float32 = 1536 bytes; NULL until embedded
    var dateIndexed: Date

    /// Decoded content position for deep-linking.
    var position: ContentPosition? {
        ContentPosition.fromJSON(positionJSON)
    }

    /// Converts a [Float] embedding to Data for storage.
    static func embeddingToData(_ embedding: [Float]) -> Data {
        embedding.withUnsafeBufferPointer { buffer in
            Data(bytes: buffer.baseAddress!, count: buffer.count * MemoryLayout<Float>.size)
        }
    }

    /// Converts stored Data back to [Float].
    static func dataToEmbedding(_ data: Data) -> [Float] {
        data.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Float.self))
        }
    }
}

// MARK: - GRDB

extension TextChunk: FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "textChunk"

    enum Columns: String, ColumnExpression {
        case id, bookId, chunkIndex, text, positionJSON, embedding, dateIndexed
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
