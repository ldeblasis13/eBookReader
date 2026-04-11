import Foundation
import GRDB
import SwiftUI

// MARK: - Annotation Tool Type

enum AnnotationTool: String, Codable, Sendable, CaseIterable {
    // Text-based (available for all formats)
    case highlight
    case underline
    case strikethrough
    case freeText
    case comment

    // Shape-based (PDF only)
    case line
    case arrow
    case circle
    case square

    var displayName: String {
        switch self {
        case .highlight: "Highlight"
        case .underline: "Underline"
        case .strikethrough: "Strikethrough"
        case .freeText: "Free Text"
        case .comment: "Comment"
        case .line: "Line"
        case .arrow: "Arrow"
        case .circle: "Circle"
        case .square: "Rectangle"
        }
    }

    var systemImage: String {
        switch self {
        case .highlight: "highlighter"
        case .underline: "underline"
        case .strikethrough: "strikethrough"
        case .freeText: "textformat"
        case .comment: "text.bubble"
        case .line: "line.diagonal"
        case .arrow: "arrow.up.right"
        case .circle: "circle"
        case .square: "square"
        }
    }

    var isTextBased: Bool {
        switch self {
        case .highlight, .underline, .strikethrough, .freeText, .comment: true
        case .line, .arrow, .circle, .square: false
        }
    }

    var isShapeTool: Bool { !isTextBased }

    /// Tools available for reflowable formats (ePub, FB2, etc.)
    static var reflowableTools: [AnnotationTool] {
        [.highlight, .underline, .strikethrough, .freeText, .comment]
    }

    /// All tools available for PDF
    static var pdfTools: [AnnotationTool] {
        allCases
    }
}

// MARK: - Annotation Color

enum AnnotationColor: String, Codable, Sendable, CaseIterable {
    case yellow
    case red
    case green
    case blue
    case purple
    case orange

    var color: Color {
        switch self {
        case .yellow: .yellow
        case .red: .red
        case .green: .green
        case .blue: .blue
        case .purple: .purple
        case .orange: .orange
        }
    }

    var nsColor: NSColor {
        switch self {
        case .yellow: .systemYellow
        case .red: .systemRed
        case .green: .systemGreen
        case .blue: .systemBlue
        case .purple: .systemPurple
        case .orange: .systemOrange
        }
    }

    var cssColor: String {
        switch self {
        case .yellow: "rgba(255, 255, 0, 0.35)"
        case .red: "rgba(255, 59, 48, 0.35)"
        case .green: "rgba(52, 199, 89, 0.35)"
        case .blue: "rgba(0, 122, 255, 0.35)"
        case .purple: "rgba(175, 82, 222, 0.35)"
        case .orange: "rgba(255, 149, 0, 0.35)"
        }
    }

    /// Solid CSS color for underline/strikethrough
    var cssSolidColor: String {
        switch self {
        case .yellow: "rgb(255, 204, 0)"
        case .red: "rgb(255, 59, 48)"
        case .green: "rgb(52, 199, 89)"
        case .blue: "rgb(0, 122, 255)"
        case .purple: "rgb(175, 82, 222)"
        case .orange: "rgb(255, 149, 0)"
        }
    }
}

// MARK: - Annotation Position

/// Encodes the location of an annotation within a book.
enum AnnotationPosition: Codable, Sendable {
    /// PDF: page index + optional rect for shapes
    case pdf(pageIndex: Int, bounds: [Double]?)

    /// Reflowable: spine/chapter index + XPath range + selected text for fallback matching
    case reflowable(
        chapterIndex: Int,
        startXPath: String,
        startOffset: Int,
        endXPath: String,
        endOffset: Int,
        selectedText: String
    )

    func toJSON() -> String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func fromJSON(_ json: String?) -> AnnotationPosition? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(AnnotationPosition.self, from: data)
    }

    /// Sort key for ordering annotations by position
    var sortKey: Double {
        switch self {
        case .pdf(let pageIndex, let bounds):
            // Sort by page, then top-to-bottom within page
            let yOffset = bounds.map { b in b.count >= 4 ? (1.0 - b[1] / 1000.0) : 0 } ?? 0
            return Double(pageIndex) + yOffset
        case .reflowable(let chapterIndex, _, let startOffset, _, _, _):
            return Double(chapterIndex) * 1_000_000 + Double(startOffset)
        }
    }
}

// MARK: - Annotation Model

struct Annotation: Identifiable, Codable, Sendable, Hashable {
    var id: UUID
    var bookId: UUID
    var tool: AnnotationTool
    var color: AnnotationColor
    var position: String          // JSON-encoded AnnotationPosition
    var selectedText: String?     // The text that was annotated (for text-based annotations)
    var note: String?             // User's comment or free text content
    var data: String?             // Additional JSON data (shape geometry, etc.)
    var dateCreated: Date
    var dateModified: Date

    init(
        id: UUID = UUID(),
        bookId: UUID,
        tool: AnnotationTool,
        color: AnnotationColor = .yellow,
        position: AnnotationPosition,
        selectedText: String? = nil,
        note: String? = nil,
        data: String? = nil,
        dateCreated: Date = Date(),
        dateModified: Date = Date()
    ) {
        self.id = id
        self.bookId = bookId
        self.tool = tool
        self.color = color
        self.position = position.toJSON() ?? "{}"
        self.selectedText = selectedText
        self.note = note
        self.data = data
        self.dateCreated = dateCreated
        self.dateModified = dateModified
    }

    var decodedPosition: AnnotationPosition? {
        AnnotationPosition.fromJSON(position)
    }

    // Hashable conformance (just id)
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: Annotation, rhs: Annotation) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - GRDB Conformance

extension Annotation: FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "annotation"

    enum Columns: String, ColumnExpression {
        case id, bookId, tool, color, position, selectedText, note, data, dateCreated, dateModified
    }
}
