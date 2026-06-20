import Foundation
import GRDB
import Accelerate

/// Hybrid semantic + keyword retrieval over memory_chunks.
///
/// Vector path: brute-force cosine similarity with vDSP (Accelerate).
///   → Zero extra dependencies; excellent SIMD throughput on Apple Silicon.
///   → For corpora beyond ~500k chunks, swap inner loop for sqlite-vec ANN.
///
/// Keyword path: FTS5 with porter stemming.
///
/// Fusion: Reciprocal Rank Fusion (RRF) with k=60.
final class MemoryStore {
    private let db: ShiroDatabase
    private let embeddings: EmbeddingService

    // RRF constant — higher k reduces sensitivity to top-rank differences
    private let rrfK: Double = 60.0

    init(database: ShiroDatabase, embeddingService: EmbeddingService) {
        self.db = database
        self.embeddings = embeddingService
    }

    // MARK: - Upsert

    /// Insert or replace a chunk (matched on source + chunk_idx).
    /// Computes embedding inline; caller must have already chunked text.
    func upsert(corpus: String, source: String, chunkIdx: Int,
                content: String, tokenCount: Int,
                metadata: [String: String]? = nil) async throws {
        let vec = try await embeddings.embed(content)
        let blob = EmbeddingService.toBlob(vec)

        try await db.pool.write { db in
            // Delete existing chunk for same source + index so triggers fire correctly
            try db.execute(
                sql: "DELETE FROM memory_chunks WHERE source = ? AND chunk_idx = ?",
                arguments: [source, chunkIdx]
            )
            var chunk = MemoryChunk.new(corpus: corpus, source: source,
                                        chunkIdx: chunkIdx, content: content,
                                        tokenCount: tokenCount, metadata: metadata)
            chunk.embedding = blob
            try chunk.insert(db)
        }
    }

    /// Batch upsert — embeds all contents in one network call.
    func upsertBatch(corpus: String, source: String,
                     chunks: [(idx: Int, content: String, tokenCount: Int,
                               metadata: [String: String]?)]) async throws {
        guard !chunks.isEmpty else { return }

        let texts = chunks.map(\.content)
        let vectors = try await embeddings.embedBatch(texts)

        guard vectors.count == chunks.count else {
            throw MemoryStoreError.embeddingCountMismatch(expected: chunks.count, got: vectors.count)
        }

        try await db.pool.write { db in
            for (i, chunk) in chunks.enumerated() {
                try db.execute(
                    sql: "DELETE FROM memory_chunks WHERE source = ? AND chunk_idx = ?",
                    arguments: [source, chunk.idx]
                )
                let blob = EmbeddingService.toBlob(vectors[i])
                var row = MemoryChunk.new(corpus: corpus, source: source,
                                          chunkIdx: chunk.idx, content: chunk.content,
                                          tokenCount: chunk.tokenCount, metadata: chunk.metadata)
                row.embedding = blob
                try row.insert(db)
            }
        }
    }

    /// Delete all chunks for a given source (e.g. on file deletion or re-ingest).
    func deleteSource(_ source: String) async throws {
        try await db.pool.write { db in
            try db.execute(sql: "DELETE FROM memory_chunks WHERE source = ?",
                           arguments: [source])
        }
    }

    // MARK: - Search

    struct SearchResult {
        let chunk: MemoryChunk
        let score: Double           // RRF fused score (higher = better)
        let vectorRank: Int?        // rank in cosine pass (nil if not in top-k)
        let ftsRank: Int?           // rank in FTS pass (nil if not in top-k)
    }

    /// Hybrid search: vector cosine + FTS5 keyword, fused via RRF.
    ///
    /// - Parameters:
    ///   - query: Natural language or keyword query
    ///   - corpus: Restrict to one corpus (nil = all)
    ///   - topK: Number of results to return
    ///   - vectorWeight: How much to weight vector vs. FTS (both weighted equally in RRF by default)
    func search(query: String, corpus: String? = nil,
                topK: Int = 8) async throws -> [SearchResult] {
        async let vectorResults = vectorSearch(query: query, corpus: corpus, topK: topK * 2)
        async let ftsResults = ftsSearch(query: query, corpus: corpus, topK: topK * 2)

        let (vecHits, kwHits) = try await (vectorResults, ftsResults)

        return rrf(vectorHits: vecHits, ftsHits: kwHits, topK: topK)
    }

    /// Pure vector search — no FTS.
    func vectorSearch(query: String, corpus: String? = nil, topK: Int = 8) async throws -> [(MemoryChunk, Double)] {
        let queryVec = try await embeddings.embed(query)
        return try await cosineScan(queryVec: queryVec, corpus: corpus, topK: topK)
    }

    /// Pure FTS keyword search — no embeddings.
    func ftsSearch(query: String, corpus: String? = nil, topK: Int = 8) async throws -> [(MemoryChunk, Double)] {
        try await db.pool.read { db in
            // Sanitize query for FTS5 — wrap each token with * for prefix matching
            let safeQuery = self.sanitizeFTSQuery(query)

            let corpusFilter = corpus.map { _ in "AND mc.corpus = ?" } ?? ""
            var args: [DatabaseValue] = [safeQuery.databaseValue]
            if let c = corpus { args.append(c.databaseValue) }
            args.append(topK.databaseValue)

            let sql = """
                SELECT mc.*, fts.rank as fts_rank
                FROM memory_chunks mc
                JOIN memory_chunks_fts fts ON mc.rowid = fts.rowid
                WHERE memory_chunks_fts MATCH ?
                \(corpusFilter)
                ORDER BY fts.rank
                LIMIT ?
            """
            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
            return rows.compactMap { row -> (MemoryChunk, Double)? in
                guard let chunk = MemoryChunk.fromRow(row) else { return nil }
                let rank = row["fts_rank"] as? Double ?? 0
                // FTS5 rank is negative; negate for "higher = better"
                return (chunk, -rank)
            }
        }
    }

    // MARK: - Corpus stats

    func chunkCount(corpus: String? = nil) async throws -> Int {
        try await db.pool.read { db in
            if let c = corpus {
                return try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM memory_chunks WHERE corpus = ?",
                                        arguments: [c]) ?? 0
            } else {
                return try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM memory_chunks") ?? 0
            }
        }
    }

    // MARK: - Vector scan (vDSP brute force)

    private func cosineScan(queryVec: [Float], corpus: String?, topK: Int) async throws -> [(MemoryChunk, Double)] {
        try await db.pool.read { db in
            // Load all chunks that have embeddings (restrict by corpus if given).
            // Combine both filters into a single WHERE — previously two WHERE clauses
            // yielded invalid SQL when corpus was set.
            let whereSQL: String
            let args: StatementArguments
            if let c = corpus {
                whereSQL = "WHERE corpus = ? AND embedding IS NOT NULL"
                args = StatementArguments([c])
            } else {
                whereSQL = "WHERE embedding IS NOT NULL"
                args = StatementArguments()
            }

            let sql = """
                SELECT id, corpus, source, source_id, chunk_idx, content,
                       embedding, embedding_dim, token_count, metadata_json,
                       created_at, updated_at
                FROM memory_chunks
                \(whereSQL)
            """
            let rows = try Row.fetchAll(db, sql: sql, arguments: args)
            if rows.isEmpty { return [] }

            // Precompute query norm
            var qNorm = Float(0)
            vDSP_svesq(queryVec, 1, &qNorm, vDSP_Length(queryVec.count))
            qNorm = sqrtf(qNorm)
            guard qNorm > 1e-9 else { return [] }

            var scored: [(MemoryChunk, Double)] = []
            scored.reserveCapacity(rows.count)

            for row in rows {
                guard let chunk = MemoryChunk.fromRow(row),
                      let blob = chunk.embedding else { continue }

                let docVec = EmbeddingService.fromBlob(blob)
                guard docVec.count == queryVec.count else { continue }

                // dot product
                var dot = Float(0)
                vDSP_dotpr(queryVec, 1, docVec, 1, &dot, vDSP_Length(queryVec.count))

                // doc norm
                var dNorm = Float(0)
                vDSP_svesq(docVec, 1, &dNorm, vDSP_Length(docVec.count))
                dNorm = sqrtf(dNorm)

                guard dNorm > 1e-9 else { continue }
                let cosine = Double(dot / (qNorm * dNorm))
                scored.append((chunk, cosine))
            }

            // Partial sort — keep top-K by score
            scored.sort { $0.1 > $1.1 }
            return Array(scored.prefix(topK))
        }
    }

    // MARK: - Reciprocal Rank Fusion

    private func rrf(vectorHits: [(MemoryChunk, Double)],
                     ftsHits: [(MemoryChunk, Double)],
                     topK: Int) -> [SearchResult] {
        var scores: [String: Double] = [:]         // chunk id → RRF score
        var vecRankMap: [String: Int] = [:]
        var ftsRankMap: [String: Int] = [:]
        var chunkMap: [String: MemoryChunk] = [:]

        for (rank, (chunk, _)) in vectorHits.enumerated() {
            scores[chunk.id, default: 0] += 1.0 / (rrfK + Double(rank + 1))
            vecRankMap[chunk.id] = rank + 1
            chunkMap[chunk.id] = chunk
        }
        for (rank, (chunk, _)) in ftsHits.enumerated() {
            scores[chunk.id, default: 0] += 1.0 / (rrfK + Double(rank + 1))
            ftsRankMap[chunk.id] = rank + 1
            chunkMap[chunk.id] = chunk
        }

        return scores
            .sorted { $0.value > $1.value }
            .prefix(topK)
            .compactMap { (id, score) -> SearchResult? in
                guard let chunk = chunkMap[id] else { return nil }
                return SearchResult(
                    chunk: chunk,
                    score: score,
                    vectorRank: vecRankMap[id],
                    ftsRank: ftsRankMap[id]
                )
            }
    }

    // MARK: - FTS query sanitisation

    private func sanitizeFTSQuery(_ raw: String) -> String {
        // FTS5 reserves: " ( ) * : ^ - + as well as the words AND / OR / NOT / NEAR.
        // Strategy: strip all punctuation the user typed, lowercase any reserved
        // keywords so FTS5 treats them as regular tokens, then wrap each token
        // in double quotes + append * for prefix matching.
        //
        // "\"foo bar AND baz\"" → "\"foo\"* \"bar\"* \"and\"* \"baz\"*"
        let reserved: Set<String> = ["AND", "OR", "NOT", "NEAR"]
        let cleaned = raw.replacingOccurrences(
            of: #"[\"()*:^\-+]"#, with: " ", options: .regularExpression
        )
        let tokens = cleaned
            .split(whereSeparator: { $0.isWhitespace })
            .map { tok -> String in
                var s = String(tok)
                if reserved.contains(s.uppercased()) { s = s.lowercased() }
                // Escape any stray double-quote (already stripped above, but belt-and-braces)
                s = s.replacingOccurrences(of: "\"", with: "")
                return "\"\(s)\"*"
            }
        if tokens.isEmpty { return "\"\(raw.replacingOccurrences(of: "\"", with: ""))\"" }
        return tokens.joined(separator: " ")
    }
}

// MARK: - MemoryStoreError

enum MemoryStoreError: LocalizedError {
    case embeddingCountMismatch(expected: Int, got: Int)
    var errorDescription: String? {
        switch self {
        case .embeddingCountMismatch(let e, let g):
            return "Embedding batch returned \(g) vectors for \(e) chunks"
        }
    }
}

// MARK: - MemoryChunk row initializer

private extension MemoryChunk {
    static func fromRow(_ row: Row) -> MemoryChunk? {
        guard let id = row["id"] as? String,
              let corpus = row["corpus"] as? String,
              let source = row["source"] as? String,
              let content = row["content"] as? String else { return nil }

        return MemoryChunk(
            id: id,
            corpus: corpus,
            source: source,
            sourceId: row["source_id"] as? String,
            chunkIdx: row["chunk_idx"] as? Int ?? 0,
            content: content,
            embedding: row["embedding"] as? Data,
            embeddingDim: row["embedding_dim"] as? Int ?? 768,
            tokenCount: row["token_count"] as? Int ?? 0,
            metadataJSON: row["metadata_json"] as? String,
            createdAt: row["created_at"] as? Date ?? Date(),
            updatedAt: row["updated_at"] as? Date ?? Date()
        )
    }
}
