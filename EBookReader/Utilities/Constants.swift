import Foundation

enum Constants {
    static let appName = "EBookReader"

    enum Directories {
        static var applicationSupport: URL {
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent("EBookReader", isDirectory: true)
        }

        static var caches: URL {
            FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
                .appendingPathComponent("EBookReader", isDirectory: true)
        }

        static var thumbnailCache: URL {
            caches.appendingPathComponent("Thumbnails", isDirectory: true)
        }

        static var epubExtractedCache: URL {
            caches.appendingPathComponent("EPubExtracted", isDirectory: true)
        }

        static var models: URL {
            applicationSupport.appendingPathComponent("Models", isDirectory: true)
        }

        static func ensureDirectoriesExist() throws {
            let fm = FileManager.default
            for dir in [applicationSupport, caches, thumbnailCache, epubExtractedCache, models] {
                if !fm.fileExists(atPath: dir.path) {
                    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                }
            }
        }
    }

    enum Thumbnail {
        static let width: CGFloat = 180
        static let height: CGFloat = 260
        static let jpegQuality: CGFloat = 0.8
    }

    enum Models {
        static let embeddingModelId = "embedding-minilm"
        static let llmModelId = "llm-gemma"
        static let embeddingDimension = 384
        static let embeddingBlobSize = 384 * MemoryLayout<Float>.size // 1536
        static let chunkWordCount = 400 // ~512 tokens for MiniLM context window
    }

    enum Library {
        static let gridItemMinWidth: CGFloat = 160
        static let gridItemMaxWidth: CGFloat = 200
        static let gridSpacing: CGFloat = 16
    }
}
