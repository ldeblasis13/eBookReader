import Foundation

struct ReaderTab: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var bookID: UUID
    var bookTitle: String

    init(id: UUID = UUID(), bookID: UUID, bookTitle: String) {
        self.id = id
        self.bookID = bookID
        self.bookTitle = bookTitle
    }
}

// MARK: - Reading Position

/// Encodes the reading position for any format. Stored as JSON in Book.lastReadPosition.
enum ReadingPosition: Codable, Sendable {
    case pdf(pageIndex: Int, scrollFraction: Double)
    case epub(spineIndex: Int, scrollFraction: Double)
    case fb2(scrollFraction: Double)
    case webBased(scrollFraction: Double) // fallback for mobi, azw3, chm

    private enum CodingKeys: String, CodingKey {
        case type, pageIndex, spineIndex, scrollFraction
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "pdf":
            let pageIndex = try container.decode(Int.self, forKey: .pageIndex)
            let scrollFraction = try container.decodeIfPresent(Double.self, forKey: .scrollFraction) ?? 0
            self = .pdf(pageIndex: pageIndex, scrollFraction: scrollFraction)
        case "epub":
            let spineIndex = try container.decode(Int.self, forKey: .spineIndex)
            let scrollFraction = try container.decodeIfPresent(Double.self, forKey: .scrollFraction) ?? 0
            self = .epub(spineIndex: spineIndex, scrollFraction: scrollFraction)
        case "fb2":
            let scrollFraction = try container.decodeIfPresent(Double.self, forKey: .scrollFraction) ?? 0
            self = .fb2(scrollFraction: scrollFraction)
        default:
            let scrollFraction = try container.decodeIfPresent(Double.self, forKey: .scrollFraction) ?? 0
            self = .webBased(scrollFraction: scrollFraction)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .pdf(let pageIndex, let scrollFraction):
            try container.encode("pdf", forKey: .type)
            try container.encode(pageIndex, forKey: .pageIndex)
            try container.encode(scrollFraction, forKey: .scrollFraction)
        case .epub(let spineIndex, let scrollFraction):
            try container.encode("epub", forKey: .type)
            try container.encode(spineIndex, forKey: .spineIndex)
            try container.encode(scrollFraction, forKey: .scrollFraction)
        case .fb2(let scrollFraction):
            try container.encode("fb2", forKey: .type)
            try container.encode(scrollFraction, forKey: .scrollFraction)
        case .webBased(let scrollFraction):
            try container.encode("web", forKey: .type)
            try container.encode(scrollFraction, forKey: .scrollFraction)
        }
    }

    /// Encode to a JSON string for storage in Book.lastReadPosition.
    func toJSON() -> String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Decode from a JSON string stored in Book.lastReadPosition.
    static func fromJSON(_ json: String?) -> ReadingPosition? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ReadingPosition.self, from: data)
    }
}
