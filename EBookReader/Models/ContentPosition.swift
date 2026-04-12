import Foundation

/// Format-agnostic position encoding for text chunks.
/// Enables deep-linking from search results to the exact location in a book.
enum ContentPosition: Codable, Sendable, Hashable {
    case pdf(pageIndex: Int)
    case epub(spineIndex: Int, href: String)
    case fb2(sectionIndex: Int)
    case mobi(offsetFraction: Double)
    case chm(fileIndex: Int, fileName: String)

    func toJSON() -> String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func fromJSON(_ json: String?) -> ContentPosition? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ContentPosition.self, from: data)
    }
}
