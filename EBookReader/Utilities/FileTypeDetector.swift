import Foundation
import UniformTypeIdentifiers

struct FileTypeDetector {
    static func detectFormat(from url: URL) -> BookFormat? {
        let ext = url.pathExtension.lowercased()
        return BookFormat(rawValue: ext)
    }

    static func isSupportedBookFile(_ url: URL) -> Bool {
        detectFormat(from: url) != nil
    }

    static let supportedExtensions = BookFormat.supportedExtensions
}
