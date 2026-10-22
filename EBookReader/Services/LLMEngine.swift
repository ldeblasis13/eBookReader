import Foundation
import Accelerate
import LlamaCpp
import os

/// Swift wrapper around llama.cpp for embedding generation and text generation.
actor LLMEngine {
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "EBookReader",
        category: "LLMEngine"
    )

    private var embeddingModel: OpaquePointer?
    private var embeddingContext: OpaquePointer?
    private var generationModel: OpaquePointer?
    private var generationContext: OpaquePointer?

    private var isEmbeddingLoaded = false
    private var isGenerationLoaded = false

    init() {
        llama_backend_init()
    }

    /// Must be called before app exit to prevent Metal resource cleanup crash.
    func shutdown() {
        unloadEmbeddingModel()
        unloadGenerationModel()
        llama_backend_free()
    }

    // MARK: - Model Loading

    private var embeddingModelPath: String?

    func loadEmbeddingModel(path: String) throws {
        guard !isEmbeddingLoaded else { return }
        logger.info("Embedding model will be loaded on first use from: \(path)")
        embeddingModelPath = path
        isEmbeddingLoaded = true
    }

    private func ensureEmbeddingModelLoaded() throws {
        guard embeddingContext == nil, let path = embeddingModelPath else { return }
        logger.info("Deferred loading embedding model from: \(path)")

        var modelParams = llama_model_default_params()
        modelParams.n_gpu_layers = 99

        guard let model = llama_model_load_from_file(path, modelParams) else {
            isEmbeddingLoaded = false
            throw LLMEngineError.modelNotLoaded
        }
        embeddingModel = model

        var ctxParams = llama_context_default_params()
        ctxParams.n_ctx = 512
        ctxParams.n_batch = 512
        ctxParams.n_threads = Int32(max(1, ProcessInfo.processInfo.processorCount - 2))
        ctxParams.n_threads_batch = ctxParams.n_threads
        ctxParams.embeddings = true
        // Pool token outputs into one sentence vector. UNSPECIFIED takes the
        // pooling the GGUF declares; if it declares none, use mean pooling,
        // which is what sentence-transformers models like MiniLM train with.
        ctxParams.pooling_type = LLAMA_POOLING_TYPE_UNSPECIFIED

        guard var ctx = llama_init_from_model(model, ctxParams) else {
            llama_model_free(model)
            embeddingModel = nil
            isEmbeddingLoaded = false
            throw LLMEngineError.modelNotLoaded
        }
        let declaredPooling = llama_pooling_type(ctx)
        if declaredPooling == LLAMA_POOLING_TYPE_NONE || declaredPooling == LLAMA_POOLING_TYPE_RANK {
            llama_free(ctx)
            ctxParams.pooling_type = LLAMA_POOLING_TYPE_MEAN
            guard let meanCtx = llama_init_from_model(model, ctxParams) else {
                llama_model_free(model)
                embeddingModel = nil
                isEmbeddingLoaded = false
                throw LLMEngineError.modelNotLoaded
            }
            ctx = meanCtx
        }
        embeddingContext = ctx
        logger.info("Embedding model loaded successfully (pooling type \(llama_pooling_type(ctx).rawValue))")
    }

    func loadGenerationModel(path: String) throws {
        guard !isGenerationLoaded else { return }
        logger.info("Generation model will be loaded on first use from: \(path)")
        // Store path for deferred loading — the actual llama_model_load_from_file
        // call happens in generate() on first use, running on a detached task
        // to avoid blocking the actor during the heavy 2.3GB load.
        generationModelPath = path
        isGenerationLoaded = true // mark as "available" so generate() proceeds
    }

    private var generationModelPath: String?

    private func ensureGenerationModelLoaded() throws {
        guard generationContext == nil, let path = generationModelPath else { return }
        logger.info("Deferred loading generation model from: \(path)")

        var modelParams = llama_model_default_params()
        modelParams.n_gpu_layers = 99

        guard let model = llama_model_load_from_file(path, modelParams) else {
            logger.error("llama_model_load_from_file returned nil")
            isGenerationLoaded = false
            throw LLMEngineError.modelNotLoaded
        }
        generationModel = model

        var ctxParams = llama_context_default_params()
        ctxParams.n_ctx = 32768
        ctxParams.n_batch = 512
        ctxParams.n_threads = Int32(max(1, ProcessInfo.processInfo.processorCount - 2))
        ctxParams.n_threads_batch = ctxParams.n_threads
        ctxParams.embeddings = false

        guard let ctx = llama_init_from_model(model, ctxParams) else {
            llama_model_free(model)
            generationModel = nil
            isGenerationLoaded = false
            throw LLMEngineError.modelNotLoaded
        }
        generationContext = ctx
        logger.info("Generation model loaded successfully")
    }

    /// Eagerly loads the generation model in the background so it's ready when chat is opened.
    func preloadGenerationModel() throws {
        try ensureGenerationModelLoaded()
    }

    /// Eagerly loads the embedding model in the background.
    func preloadEmbeddingModel() throws {
        try ensureEmbeddingModelLoaded()
    }

    // MARK: - Embedding

    func embed(text: String) throws -> [Float] {
        try ensureEmbeddingModelLoaded()
        guard let ctx = embeddingContext, let model = embeddingModel else {
            throw LLMEngineError.modelNotLoaded
        }

        let vocab = llama_model_get_vocab(model)

        // Tokenize. If the text is too long for the embedding context, truncate
        // by character length and retry rather than failing the whole batch.
        let maxTokens: Int32 = Int32(Constants.Models.embeddingMaxTokens)
        var input = text
        var tokens = [llama_token](repeating: 0, count: Int(maxTokens))
        var nTokens = llama_tokenize(vocab, input, Int32(input.utf8.count), &tokens, maxTokens, true, true)

        // llama_tokenize returns the negated required size when buffer is too small.
        // Truncate progressively until it fits.
        var truncations = 0
        while nTokens < 0 && truncations < 4 {
            // Cut text by ~25% each iteration
            let newCount = max(50, input.count * 3 / 4)
            input = String(input.prefix(newCount))
            nTokens = llama_tokenize(vocab, input, Int32(input.utf8.count), &tokens, maxTokens, true, true)
            truncations += 1
        }
        if truncations > 0 {
            logger.warning("Embedding text truncated \(truncations)x to fit context (final tokens: \(nTokens))")
        }
        guard nTokens > 0 else {
            logger.error("Embedding tokenization failed after truncation attempts")
            throw LLMEngineError.tokenizationFailed
        }

        // Clear memory
        let mem = llama_get_memory(ctx)
        llama_memory_clear(mem, true)

        // Encode using batch_get_one (simple API)
        let batch = llama_batch_get_one(&tokens, nTokens)
        let result = llama_encode(ctx, batch)
        guard result == 0 else { throw LLMEngineError.inferenceFailed }

        // Read the pooled sentence embedding for sequence 0 (the only one
        // llama_batch_get_one uses). llama_get_embeddings would return
        // per-token rows (or NULL once pooling is on), not a sentence vector.
        let nEmbd = Int(llama_model_n_embd(model))
        guard let embPtr = llama_get_embeddings_seq(ctx, 0) else {
            throw LLMEngineError.inferenceFailed
        }

        var embedding = Array(UnsafeBufferPointer(start: embPtr, count: nEmbd))

        // L2 normalize
        var norm: Float = 0
        vDSP_dotpr(embedding, 1, embedding, 1, &norm, vDSP_Length(embedding.count))
        norm = sqrt(norm)
        if norm > 0 {
            var scale = 1.0 / norm
            vDSP_vsmul(embedding, 1, &scale, &embedding, 1, vDSP_Length(embedding.count))
        }

        return embedding
    }

    func embedBatch(texts: [String]) throws -> [[Float]] {
        try texts.map { try embed(text: $0) }
    }

    // MARK: - Tokenization

    /// Prompt tokens generate() accepts before truncating, after reserving
    /// room for `maxResponseTokens`. Lets callers budget a prompt up front.
    func promptTokenBudget(maxResponseTokens: Int) throws -> Int {
        try ensureGenerationModelLoaded()
        guard let ctx = generationContext else { throw LLMEngineError.modelNotLoaded }
        return Int(Self.promptTokenLimit(contextSize: Int32(llama_n_ctx(ctx)), maxTokens: maxResponseTokens))
    }

    /// Counts each text in generation-model tokens (no BOS), parsing chat
    /// template markers like `<start_of_turn>` as the single tokens they are.
    /// Takes a batch so a caller pays one actor hop, not one per section.
    func countTokens(_ texts: [String]) throws -> [Int] {
        try ensureGenerationModelLoaded()
        guard let model = generationModel else { throw LLMEngineError.modelNotLoaded }
        let vocab = llama_model_get_vocab(model)
        return try texts.map { text in
            try Self.tokenize(text, vocab: vocab, addSpecial: false, initialCapacity: text.utf8.count / 3 + 16).count
        }
    }

    private static func promptTokenLimit(contextSize nCtx: Int32, maxTokens: Int) -> Int32 {
        nCtx - Int32(min(maxTokens, Int(nCtx / 2)))
    }

    /// llama_tokenize returns the negated required size when the buffer is
    /// too small. Grow the buffer and retry rather than using a partially
    /// filled (zeroed) one.
    private static func tokenize(_ text: String, vocab: OpaquePointer?, addSpecial: Bool, initialCapacity: Int) throws -> [llama_token] {
        let byteCount = Int32(text.utf8.count)
        var tokens = [llama_token](repeating: 0, count: max(initialCapacity, 16))
        var nTokens = llama_tokenize(vocab, text, byteCount, &tokens, Int32(tokens.count), addSpecial, true)
        if nTokens < 0 && nTokens != Int32.min {
            tokens = [llama_token](repeating: 0, count: Int(-nTokens))
            nTokens = llama_tokenize(vocab, text, byteCount, &tokens, Int32(tokens.count), addSpecial, true)
        }
        guard nTokens >= 0 else { throw LLMEngineError.tokenizationFailed }
        return Array(tokens.prefix(Int(nTokens)))
    }

    // MARK: - Generation

    func generate(prompt: String, maxTokens: Int = 1024, temperature: Float = 0.7, topP: Float = 0.9) throws -> String {
        try ensureGenerationModelLoaded()

        guard let ctx = generationContext, let model = generationModel else {
            throw LLMEngineError.modelNotLoaded
        }

        let vocab = llama_model_get_vocab(model)
        let nCtx = Int32(llama_n_ctx(ctx))

        // Tokenize prompt — leave room for response tokens
        let safePromptLimit = Self.promptTokenLimit(contextSize: nCtx, maxTokens: maxTokens)
        var tokens = try Self.tokenize(prompt, vocab: vocab, addSpecial: true, initialCapacity: Int(max(safePromptLimit, 1024)))

        // Still too long? Callers budget their prompts (ChatManager), so this
        // is a last resort. Cut from the middle: the head holds the
        // instructions and the tail holds the question plus the model-turn
        // marker, and losing either one produces garbage.
        if tokens.count > Int(safePromptLimit) {
            let tailCount = min(Int(safePromptLimit) / 4, 1024)
            let headCount = Int(safePromptLimit) - tailCount
            logger.warning("Prompt truncated from \(tokens.count) to \(safePromptLimit) tokens (context limit: \(nCtx))")
            tokens = Array(tokens.prefix(headCount) + tokens.suffix(tailCount))
        }
        let nTokens = Int32(tokens.count)
        guard nTokens > 0 else { throw LLMEngineError.tokenizationFailed }

        // Clear memory
        let mem = llama_get_memory(ctx)
        llama_memory_clear(mem, true)

        // Process prompt in batches of n_batch to avoid overflow
        let nBatch: Int32 = 512
        var result: Int32 = 0
        var i: Int32 = 0
        while i < nTokens {
            let batchSize = min(nBatch, nTokens - i)
            var batchTokens = Array(tokens[Int(i)..<Int(i + batchSize)])
            let batch = llama_batch_get_one(&batchTokens, batchSize)
            result = llama_decode(ctx, batch)
            if result != 0 { break }
            i += batchSize
        }
        guard result == 0 else { throw LLMEngineError.inferenceFailed }

        // Create sampler. For low temperature (≤0.05) use greedy sampling for determinism.
        let sampler = llama_sampler_chain_init(llama_sampler_chain_default_params())!
        if temperature <= 0.05 {
            llama_sampler_chain_add(sampler, llama_sampler_init_greedy())
        } else {
            llama_sampler_chain_add(sampler, llama_sampler_init_temp(temperature))
            llama_sampler_chain_add(sampler, llama_sampler_init_top_p(topP, 1))
            llama_sampler_chain_add(sampler, llama_sampler_init_dist(UInt32.random(in: 0...UInt32.max)))
        }

        // Generate tokens — hard stop before context overflow
        var output = ""
        var nCur = nTokens
        let eosToken = llama_vocab_eos(vocab)
        let eotToken = llama_vocab_eot(vocab)
        let hardLimit = nCtx - 2 // never reach the absolute edge

        for _ in 0..<maxTokens {
            // CRASH PREVENTION: stop before overflowing context
            if nCur >= hardLimit {
                logger.warning("Stopping generation: context limit reached (\(nCur)/\(nCtx))")
                break
            }

            let newToken = llama_sampler_sample(sampler, ctx, -1)
            if newToken == eosToken || newToken == eotToken { break }

            // Convert token to text
            var buf = [CChar](repeating: 0, count: 256)
            let len = llama_token_to_piece(vocab, newToken, &buf, 256, 0, true)
            if len > 0 {
                buf[Int(len)] = 0
                let piece = String(cString: buf)
                if piece.contains("<end_of_turn>") || piece.contains("<eos>") {
                    let clean = piece.replacingOccurrences(of: "<end_of_turn>", with: "")
                        .replacingOccurrences(of: "<eos>", with: "")
                    output += clean
                    break
                }
                output += piece
            }

            // Decode next token
            var nextToken = newToken
            let nextBatch = llama_batch_get_one(&nextToken, 1)
            result = llama_decode(ctx, nextBatch)
            if result != 0 { break }
            nCur += 1
        }

        llama_sampler_free(sampler)
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Cleanup

    func unloadEmbeddingModel() {
        if let ctx = embeddingContext { llama_free(ctx) }
        if let model = embeddingModel { llama_model_free(model) }
        embeddingContext = nil
        embeddingModel = nil
        isEmbeddingLoaded = false
        logger.info("Embedding model unloaded")
    }

    func unloadGenerationModel() {
        if let ctx = generationContext { llama_free(ctx) }
        if let model = generationModel { llama_model_free(model) }
        generationContext = nil
        generationModel = nil
        isGenerationLoaded = false
        logger.info("Generation model unloaded")
    }

    // MARK: - Utility

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

    static func batchCosineSimilarity(query: [Float], matrix: [[Float]]) -> [Float] {
        matrix.map { cosineSimilarity(query, $0) }
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
