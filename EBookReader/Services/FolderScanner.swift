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
            let enumerated = Self.forEachBookFile(in: folderURL) { info in
                continuation.yield(info)
            }
            if !enumerated {
                logger.error("Failed to create enumerator for \(folderURL.path)")
            }
            continuation.finish()
        }
    }

    /// Calls `body` for every supported book file under `folderURL`, skipping
    /// hidden files and package contents. The library reconcile uses this
    /// too, so it sees exactly the files a scan would import.
    /// Returns false if the folder couldn't be enumerated.
    @discardableResult
    static func forEachBookFile(
        in folderURL: URL,
        fileManager: FileManager = .default,
        _ body: (ScannedBookInfo) -> Void
    ) -> Bool {
        let resourceKeys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey, .isDirectoryKey]

        guard let enumerator = fileManager.enumerator(
            at: folderURL,
            includingPropertiesForKeys: resourceKeys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return false
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
                body(ScannedBookInfo(
                    url: fileURL,
                    fileName: fileURL.lastPathComponent,
                    format: format,
                    fileSize: fileSize
                ))
            }
        }
        return true
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
