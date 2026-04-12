import Foundation
import CryptoKit
import GRDB
import os

/// Downloads, verifies, and manages ML model files.
/// Models are stored in ~/Library/Application Support/EBookReader/Models/.
actor ModelDownloadManager {
    private let dbPool: DatabasePool
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "EBookReader",
        category: "ModelDownloadManager"
    )

    struct DownloadProgress: Sendable {
        let modelId: String
        let displayName: String
        let bytesDownloaded: Int64
        let totalBytes: Int64
        var fraction: Double {
            guard totalBytes > 0 else { return 0 }
            return Double(bytesDownloaded) / Double(totalBytes)
        }
    }

    init(dbPool: DatabasePool) {
        self.dbPool = dbPool
    }

    // MARK: - Registration

    /// Registers the known models in the database on first run.
    func ensureModelsRegistered() async {
        let repo = ModelInfoRepository(dbPool: dbPool)

        let embeddingModel = ModelInfo(
            id: Constants.Models.embeddingModelId,
            displayName: "Sentence Embeddings (MiniLM)",
            fileName: "all-MiniLM-L6-v2-Q8_0.gguf",
            expectedSizeBytes: 80_000_000, // ~80MB
            sha256: nil, // TODO: set after hosting the converted GGUF
            downloadURL: "https://huggingface.co/leliuga/all-MiniLM-L6-v2-GGUF/resolve/main/all-MiniLM-L6-v2.Q8_0.gguf",
            localPath: nil,
            status: .pending,
            downloadedBytes: 0,
            dateDownloaded: nil
        )

        let llmModel = ModelInfo(
            id: Constants.Models.llmModelId,
            displayName: "Gemma 4 E2B (Language Model)",
            fileName: "gemma-4-e2b-Q4_K_M.gguf",
            expectedSizeBytes: 1_800_000_000, // ~1.8GB
            sha256: nil,
            downloadURL: "https://huggingface.co/bartowski/google_gemma-3-4b-it-GGUF/resolve/main/google_gemma-3-4b-it-Q4_K_M.gguf",
            localPath: nil,
            status: .pending,
            downloadedBytes: 0,
            dateDownloaded: nil
        )

        try? await repo.insertIfMissing(embeddingModel)
        try? await repo.insertIfMissing(llmModel)

        // Verify existing model files on startup
        for modelId in [Constants.Models.embeddingModelId, Constants.Models.llmModelId] {
            if let model = try? await repo.fetch(id: modelId), model.status == .ready {
                let filePath = Constants.Directories.models
                    .appendingPathComponent(model.fileName).path
                if !FileManager.default.fileExists(atPath: filePath) {
                    logger.warning("Model file missing, resetting status: \(model.displayName)")
                    try? await repo.updateStatus(id: modelId, status: .pending)
                }
            }
        }
    }

    // MARK: - Download

    /// Downloads all models with status != .ready.
    func downloadAllPendingModels(
        onProgress: @Sendable @escaping (DownloadProgress) -> Void
    ) async throws {
        let repo = ModelInfoRepository(dbPool: dbPool)
        let models = (try? await repo.fetchAll()) ?? []

        for model in models where model.status != .ready {
            try await downloadModel(model, repo: repo, onProgress: onProgress)
        }
    }

    /// Downloads a single model with resume support.
    private func downloadModel(
        _ model: ModelInfo,
        repo: ModelInfoRepository,
        onProgress: @Sendable @escaping (DownloadProgress) -> Void
    ) async throws {
        let destURL = Constants.Directories.models.appendingPathComponent(model.fileName)
        let partialURL = destURL.appendingPathExtension("partial")

        try? await repo.updateStatus(id: model.id, status: .downloading)

        // Check for existing partial download
        var resumeOffset: Int64 = 0
        if FileManager.default.fileExists(atPath: partialURL.path),
           let attrs = try? FileManager.default.attributesOfItem(atPath: partialURL.path),
           let size = attrs[.size] as? Int64 {
            resumeOffset = size
        }

        // Build request with optional Range header for resume
        guard let url = URL(string: model.downloadURL) else {
            try? await repo.updateStatus(id: model.id, status: .error)
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        if resumeOffset > 0 {
            request.setValue("bytes=\(resumeOffset)-", forHTTPHeaderField: "Range")
            logger.info("Resuming download of \(model.displayName) from byte \(resumeOffset)")
        }

        // Stream download
        let (asyncBytes, response) = try await URLSession.shared.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) || httpResponse.statusCode == 206 else {
            try? await repo.updateStatus(id: model.id, status: .error)
            throw URLError(.badServerResponse)
        }

        // Open file for writing (append if resuming)
        let fileHandle: FileHandle
        if resumeOffset > 0, FileManager.default.fileExists(atPath: partialURL.path) {
            fileHandle = try FileHandle(forWritingTo: partialURL)
            fileHandle.seekToEndOfFile()
        } else {
            FileManager.default.createFile(atPath: partialURL.path, contents: nil)
            fileHandle = try FileHandle(forWritingTo: partialURL)
        }

        var bytesWritten = resumeOffset
        var buffer = Data()
        let flushSize = 1_048_576 // 1MB flush interval
        var lastProgressReport = Date.distantPast

        for try await byte in asyncBytes {
            buffer.append(byte)

            if buffer.count >= flushSize {
                fileHandle.write(buffer)
                bytesWritten += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)

                // Throttle progress reports to every 0.3s
                let now = Date()
                if now.timeIntervalSince(lastProgressReport) > 0.3 {
                    lastProgressReport = now
                    try? await repo.updateDownloadProgress(id: model.id, bytes: bytesWritten)
                    let progress = DownloadProgress(
                        modelId: model.id,
                        displayName: model.displayName,
                        bytesDownloaded: bytesWritten,
                        totalBytes: model.expectedSizeBytes
                    )
                    onProgress(progress)
                }
            }
        }

        // Flush remaining buffer
        if !buffer.isEmpty {
            fileHandle.write(buffer)
            bytesWritten += Int64(buffer.count)
        }
        fileHandle.closeFile()

        // Move partial to final destination
        if FileManager.default.fileExists(atPath: destURL.path) {
            try FileManager.default.removeItem(at: destURL)
        }
        try FileManager.default.moveItem(at: partialURL, to: destURL)

        // Verify SHA-256 if available
        if let expectedHash = model.sha256 {
            let fileData = try Data(contentsOf: destURL)
            let hash = SHA256.hash(data: fileData)
            let hashString = hash.map { String(format: "%02x", $0) }.joined()
            if hashString != expectedHash {
                logger.error("SHA-256 mismatch for \(model.displayName)")
                try? FileManager.default.removeItem(at: destURL)
                try? await repo.updateStatus(id: model.id, status: .error)
                return
            }
        }

        // Mark ready
        try? await repo.markReady(id: model.id, localPath: destURL.path)
        logger.info("Model downloaded successfully: \(model.displayName) (\(bytesWritten) bytes)")

        onProgress(DownloadProgress(
            modelId: model.id,
            displayName: model.displayName,
            bytesDownloaded: bytesWritten,
            totalBytes: model.expectedSizeBytes
        ))
    }

    // MARK: - Status

    func verifyModel(id: String) async -> Bool {
        let repo = ModelInfoRepository(dbPool: dbPool)
        guard let model = try? await repo.fetch(id: id), model.status == .ready else { return false }
        guard let path = model.localPath else { return false }
        return FileManager.default.fileExists(atPath: path)
    }

    func modelPath(id: String) async -> URL? {
        let repo = ModelInfoRepository(dbPool: dbPool)
        guard let model = try? await repo.fetch(id: id),
              model.status == .ready,
              let path = model.localPath else { return nil }
        return URL(fileURLWithPath: path)
    }
}
