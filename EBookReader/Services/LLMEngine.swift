import Foundation
import Accelerate
import os

/// Swift wrapper around llama.cpp for embedding generation and text generation.
/// Both the embedding model (MiniLM) and LLM (Gemma) share this engine.
/// Models are loaded lazily on first use and can be unloaded to free memory.
actor LLMEngine {
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "EBookReader",
        category: "LLMEngine"
    )

    // llama.cpp context pointers (OpaquePointer when linked)
    private var embeddingModel: OpaquePointer?
    private var embeddingContext: OpaquePointer?
    private var generationModel: OpaquePointer?
    private var generationContext: OpaquePointer?

    private var isEmbeddingLoaded = false
    private var isGenerationLoaded = false

    // MARK: - Model Loading

    /// Loads the embedding model (all-MiniLM-L6-v2 GGUF).
    func loadEmbeddingModel(path: String) throws {
        guard !isEmbeddingLoaded else { return }
        // TODO: Call llama_model_load_from_file + llama_new_context_with_model
        // with embedding=true, n_ctx=512, n_batch=512
        // For now, mark as loaded so the pipeline can proceed
        logger.info("Loading embedding model from: \(path)")
        isEmbeddingLoaded = true
    }

    /// Loads the generation model (Gemma 4 E2B GGUF).
    func loadGenerationModel(path: String) throws {
        guard !isGenerationLoaded else { return }
        logger.info("Loading generation model from: \(path)")
        isGenerationLoaded = true
    }

    // MARK: - Embedding

    /// Generates a normalized embedding vector for a single text.
    func embed(text: String) throws -> [Float] {
        guard isEmbeddingLoaded else {
            throw LLMEngineError.modelNotLoaded
        }

        // TODO: Replace with actual llama.cpp embedding call:
        // 1. llama_tokenize(model, text, tokens, max_tokens, true, true)
        // 2. llama_encode(ctx, batch)
        // 3. llama_get_embeddings(ctx) → pointer to float array
        // 4. Normalize to unit vector

        // Placeholder: return a deterministic hash-based vector for development
        return placeholderEmbedding(for: text)
    }

    /// Batch embedding for efficiency.
    func embedBatch(texts: [String]) throws -> [[Float]] {
        try texts.map { try embed(text: $0) }
    }

    // MARK: - Generation (for Milestone 12)

    /// Generates text from a prompt using the LLM.
    func generate(prompt: String, maxTokens: Int = 512) throws -> String {
        guard isGenerationLoaded else {
            throw LLMEngineError.modelNotLoaded
        }
        // TODO: Implement with llama_decode loop
        return "[LLM generation not yet implemented]"
    }

    // MARK: - Cleanup

    func unloadEmbeddingModel() {
        // TODO: llama_free(embeddingContext), llama_free_model(embeddingModel)
        embeddingContext = nil
        embeddingModel = nil
        isEmbeddingLoaded = false
        logger.info("Embedding model unloaded")
    }

    func unloadGenerationModel() {
        generationContext = nil
        generationModel = nil
        isGenerationLoaded = false
        logger.info("Generation model unloaded")
    }

    // MARK: - Utility

    /// Cosine similarity between two vectors using Accelerate.
    static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(a.count))
        vDSP_dotpr(a, 1, a, 1, &normA, vDSP_Length(a.count))
        vDSP_dotpr(b, 1, b, 1, &normB, vDSP_Length(b.count))
        let denom = sqrt(normA) * sqrt(normB)
        return denom > 0 ? dot / denom : 0
    }

    /// Batch cosine similarity: query vector vs matrix of vectors.
    /// Returns array of similarities in the same order as the matrix rows.
    static func batchCosineSimilarity(query: [Float], matrix: [[Float]]) -> [Float] {
        matrix.map { cosineSimilarity(query, $0) }
    }

    // MARK: - Placeholder (remove when llama.cpp is fully wired)

    /// Generates a deterministic pseudo-embedding from text for development/testing.
    private func placeholderEmbedding(for text: String) -> [Float] {
        var vector = [Float](repeating: 0, count: Constants.Models.embeddingDimension)
        let words = text.lowercased().split(separator: " ")
        for (i, word) in words.prefix(Constants.Models.embeddingDimension).enumerated() {
            var hash = word.hashValue
            vector[i % Constants.Models.embeddingDimension] += Float(hash % 1000) / 1000.0
            hash = hash &>> 16
            vector[(i + 1) % Constants.Models.embeddingDimension] += Float(hash % 1000) / 1000.0
        }
        // Normalize
        var norm: Float = 0
        vDSP_dotpr(vector, 1, vector, 1, &norm, vDSP_Length(vector.count))
        norm = sqrt(norm)
        if norm > 0 {
            var scale = 1.0 / norm
            vDSP_vsmul(vector, 1, &scale, &vector, 1, vDSP_Length(vector.count))
        }
        return vector
    }
}

enum LLMEngineError: Error, LocalizedError {
    case modelNotLoaded
    case tokenizationFailed
    case inferenceFailed

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded: "ML model not loaded"
        case .tokenizationFailed: "Failed to tokenize input"
        case .inferenceFailed: "Model inference failed"
        }
    }
}
