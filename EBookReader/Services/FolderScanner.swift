import Foundation
import os

actor FolderScanner {
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "EBookReader",
        category: "FolderScanner"
    )

    struct ScanResult: Sendable {
        let booksFound: [ScannedBookInfo]
        let errors: [ScanError]
    }

    struct ScannedBookInfo: Sendable {
        let url: URL
        let fileName: String
        let format: BookFormat
        let fileSize: Int64
    }

    struct ScanError: Sendable {
        let url: URL
        let error: String
    }

    /// Scans a folder recursively for supported book files, yielding results incrementally.
    func scan(folderURL: URL) -> AsyncStream<ScannedBookInfo> {
        AsyncStream { continuation in
            let fm = FileManager.default
            let resourceKeys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey, .isDirectoryKey]

            guard let enumerator = fm.enumerator(
                at: folderURL,
                includingPropertiesForKeys: resourceKeys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else {
                logger.error("Failed to create enumerator for \(folderURL.path)")
                continuation.finish()
                return
            }

            // autoreleasepool prevents temporary URL/NSString objects from accumulating
            // in the per-iteration autorelease pool, which is critical for large libraries.
            for case let fileURL as URL in enumerator {
                autoreleasepool {
                    guard let resourceValues = try? fileURL.resourceValues(
                        forKeys: Set(resourceKeys)
                    ) else { return }

                    guard resourceValues.isRegularFile == true else { return }

                    guard let format = FileTypeDetector.detectFormat(from: fileURL) else {
                        return
                    }

                    let fileSize = Int64(resourceValues.fileSize ?? 0)
                    let info = ScannedBookInfo(
                        url: fileURL,
                        fileName: fileURL.lastPathComponent,
                        format: format,
                        fileSize: fileSize
                    )

                    continuation.yield(info)
                }
            }

            continuation.finish()
        }
    }

    /// Batch scan that returns all results at once.
    func scanAll(folderURL: URL) async -> [ScannedBookInfo] {
        var results: [ScannedBookInfo] = []
        for await info in scan(folderURL: folderURL) {
            results.append(info)
        }
        return results
    }
}
