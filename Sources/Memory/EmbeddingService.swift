import Foundation

/// Wraps LMStudioClient.embed() with batching, caching, and BLOB encoding.
/// Model: text-embedding-embeddinggemma-300m-qat → 768-dim float32.
///
/// Actor-isolated — the in-memory LRU cache was previously mutated from
/// multiple async callers without synchronization (data race / heap corruption).
actor EmbeddingService {
    private let lmStudio: LMStudioClient

    // In-memory LRU cache: text → [Float]. Bounded at maxCacheSize.
    private var cache: [String: [Float]] = [:]
    private var cacheOrder: [String] = []
    private let maxCacheSize = 512
    private let batchSize = 32

    init(lmStudio: LMStudioClient) {
        self.lmStudio = lmStudio
    }

    // MARK: - Public API

    /// Embed a single text. Returns 768-dim float vector.
    func embed(_ text: String) async throws -> [Float] {
        if let cached = cache[text] { return cached }
        let results = try await embedBatch([text])
        return results[0]
    }

    /// Embed multiple texts. Returns array aligned 1:1 with input.
    /// Respects batchSize; resolves cache hits without network round-trips.
    func embedBatch(_ texts: [String]) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }

        var results: [[Float]] = Array(repeating: [], count: texts.count)
        var missIndices: [Int] = []
        var missTexts: [String] = []

        for (i, text) in texts.enumerated() {
            if let cached = cache[text] {
                results[i] = cached
            } else {
                missIndices.append(i)
                missTexts.append(text)
            }
        }

        guard !missTexts.isEmpty else { return results }

        // Batch network calls
        let batches = missTexts.chunked(into: batchSize)
        var embeddedMisses: [[Float]] = []
        embeddedMisses.reserveCapacity(missTexts.count)

        for batch in batches {
            let batchResults = try await lmStudio.embed(texts: batch)
            guard batchResults.count == batch.count else {
                throw EmbeddingError.dimensionMismatch(
                    expected: batch.count, got: batchResults.count
                )
            }
            embeddedMisses.append(contentsOf: batchResults)
        }

        // Merge back + update cache
        for (i, idx) in missIndices.enumerated() {
            let vec = embeddedMisses[i]
            results[idx] = vec
            insertCache(key: missTexts[i], value: vec)
        }

        return results
    }

    // MARK: - Float32 BLOB codec (nonisolated — pure functions, no state)

    /// Pack [Float] → Data (little-endian float32 array, same byte layout as C float[]).
    nonisolated static func toBlob(_ vector: [Float]) -> Data {
        vector.withUnsafeBytes { Data($0) }
    }

    /// Unpack Data → [Float] (little-endian float32 array).
    nonisolated static func fromBlob(_ data: Data) -> [Float] {
        data.withUnsafeBytes { ptr in
            Array(ptr.bindMemory(to: Float.self))
        }
    }

    // MARK: - LRU cache

    private func insertCache(key: String, value: [Float]) {
        if cache.count >= maxCacheSize, let oldest = cacheOrder.first {
            cache.removeValue(forKey: oldest)
            cacheOrder.removeFirst()
        }
        // If key already present, move it to the end.
        if cache[key] != nil {
            cacheOrder.removeAll(where: { $0 == key })
        }
        cache[key] = value
        cacheOrder.append(key)
    }

    // MARK: - Errors

    enum EmbeddingError: LocalizedError {
        case dimensionMismatch(expected: Int, got: Int)
        var errorDescription: String? {
            switch self {
            case .dimensionMismatch(let e, let g):
                return "Embedding batch size mismatch — expected \(e) vectors, got \(g)"
            }
        }
    }
}

// MARK: - Array chunking

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
