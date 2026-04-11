import Foundation

enum BookFormat: String, Codable, CaseIterable, Sendable {
    case pdf
    case epub
    case chm
    case mobi
    case azw3
    case fb2

    var displayName: String {
        switch self {
        case .pdf: "PDF"
        case .epub: "ePub"
        case .chm: "CHM"
        case .mobi: "Mobi"
        case .azw3: "AZW3"
        case .fb2: "FB2"
        }
    }

    var fileExtension: String {
        rawValue
    }

    static let supportedExtensions: Set<String> = Set(allCases.map(\.fileExtension))
}
