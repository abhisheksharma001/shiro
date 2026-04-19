import Foundation
import GRDB

/// Reads files from disk, splits them into ~512-token chunks, embeds, and stores.
///
/// Supported file types:
///   - Swift / TypeScript / Python / JS (code) → function-boundary chunking
///   - Markdown → heading-boundary chunking
///   - Plain text / everything else → sliding-window word chunking
///
/// Each ingest is idempotent: re-ingest only if mtime changed.
final class Ingestor {
    private let store: MemoryStore
    private let db: ShiroDatabase

    // Chunking parameters
    private let targetTokens = 512
    private let overlapTokens = 100

    // File extensions → corpus mapping
    private static let codeExtensions: Set<String> = [
        "swift", "ts", "tsx", "js", "jsx", "py", "go", "rs", "c", "cpp", "h", "kt", "java"
    ]
    private static let docExtensions: Set<String> = [
        "md", "markdown", "txt", "rst", "adoc"
    ]
    private static let skipExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "svg", "pdf", "zip", "gz", "tar",
        "lock", "map", "min.js", "min.css", "wasm", "bin", "db", "sqlite"
    ]

    init(store: MemoryStore, database: ShiroDatabase) {
        self.store = store
        self.db = database
    }

    // MARK: - Public API

    /// Ingest a single file. Returns number of chunks stored.
    /// Skips if file is unchanged since last ingest.
    @discardableResult
    func ingestFile(_ path: String, corpus: String? = nil) async throws -> Int {
        let url = URL(fileURLWithPath: path)
        let ext = url.pathExtension.lowercased()

        // Skip known binary/generated files
        if Self.skipExtensions.contains(ext) { return 0 }

        let mtime = try fileMtime(path: path)
        let resolvedCorpus = corpus ?? corpusFor(ext: ext)

        // Check if already ingested at same mtime
        if try await isUpToDate(path: path, mtime: mtime) { return 0 }

        // Mark as processing
        try await markJob(path: path, corpus: resolvedCorpus, status: "processing", mtime: mtime)

        do {
            let text = try String(contentsOfFile: path, encoding: .utf8)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                try await markJob(path: path, corpus: resolvedCorpus, status: "done", mtime: mtime, chunkCount: 0)
                return 0
            }

            let chunks = chunk(text: text, ext: ext, source: path)

            // Remove old chunks for this source before re-inserting
            try await store.deleteSource(path)

            // Batch embed + store
            try await store.upsertBatch(corpus: resolvedCorpus, source: path, chunks: chunks)

            try await markJob(path: path, corpus: resolvedCorpus, status: "done",
                              mtime: mtime, chunkCount: chunks.count)

            print("[Ingestor] ✅ \(path) → \(chunks.count) chunks (\(resolvedCorpus))")
            return chunks.count

        } catch {
            try await markJob(path: path, corpus: resolvedCorpus, status: "failed",
                              mtime: mtime, error: error.localizedDescription)
            throw error
        }
    }

    /// Recursively ingest a directory. Skips hidden dirs and node_modules.
    func ingestDirectory(_ dirPath: String, corpus: String? = nil) async throws {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: URL(fileURLWithPath: dirPath),
            includingPropertiesForKeys: [.isRegularFileKey, .isHiddenKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return }

        var filePaths: [String] = []
        for case let fileURL as URL in enumerator {
            // Skip generated/large directories
            let components = fileURL.pathComponents
            if components.contains("node_modules") ||
               components.contains(".git") ||
               components.contains(".build") ||
               components.contains("DerivedData") {
                enumerator.skipDescendants()
                continue
            }
            let resourceValues = try? fileURL.resourceValues(forKeys: [.isRegularFileKey])
            if resourceValues?.isRegularFile == true {
                filePaths.append(fileURL.path)
            }
        }

        // Process sequentially to avoid hammering LM Studio
        for path in filePaths {
            do {
                try await ingestFile(path, corpus: corpus)
            } catch {
                print("[Ingestor] ⚠️  Skip \(path): \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Chunking

    typealias ChunkTuple = (idx: Int, content: String, tokenCount: Int,
                            metadata: [String: String]?)

    private func chunk(text: String, ext: String, source: String) -> [ChunkTuple] {
        if Self.codeExtensions.contains(ext) {
            return chunkCode(text: text, ext: ext, source: source)
        } else if Self.docExtensions.contains(ext) {
            return chunkMarkdown(text: text, source: source)
        } else {
            return chunkSlidingWindow(text: text, source: source)
        }
    }

    // Code: split on top-level function/class/struct/impl boundaries.
    // Falls back to sliding window if no boundaries detected.
    private func chunkCode(text: String, ext: String, source: String) -> [ChunkTuple] {
        // Detect function/class boundaries via simple regex patterns
        let pattern: String
        switch ext {
        case "swift":
            pattern = #"(?m)^(?:public |private |internal |fileprivate |open |final |@[\w]+\s+)*(?:func|class|struct|enum|protocol|extension|actor)\s+"#
        case "py":
            pattern = #"(?m)^(?:async\s+)?def |^class "#
        case "ts", "tsx", "js", "jsx":
            pattern = #"(?m)^(?:export\s+)?(?:async\s+)?(?:function|class|const\s+\w+\s*=\s*(?:async\s+)?(?:function|\())"#
        default:
            return chunkSlidingWindow(text: text, source: source)
        }

        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return chunkSlidingWindow(text: text, source: source)
        }

        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))

        guard !matches.isEmpty else {
            return chunkSlidingWindow(text: text, source: source)
        }

        var sections: [(start: Int, end: Int)] = []
        for (i, match) in matches.enumerated() {
            let start = match.range.location
            let end = i + 1 < matches.count ? matches[i + 1].range.location : nsText.length
            sections.append((start, end))
        }

        // Leading code before first boundary
        if sections[0].start > 0 {
            let header = nsText.substring(to: sections[0].start)
            if !header.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                sections.insert((0, sections[0].start), at: 0)
            }
        }

        // Merge small sections (< 100 tokens) with next, split large ones (> 768 tokens)
        var merged: [String] = []
        var buffer = ""

        for section in sections {
            let slice = nsText.substring(with: NSRange(location: section.start,
                                                        length: section.end - section.start))
            let tokens = estimateTokens(slice)
            if tokens < 80 {
                buffer += "\n" + slice
            } else {
                if !buffer.isEmpty {
                    merged.append(buffer)
                    buffer = ""
                }
                if tokens > targetTokens + overlapTokens {
                    // Large function → slide over it
                    let subChunks = chunkSlidingWindow(text: slice, source: source)
                    merged.append(contentsOf: subChunks.map(\.content))
                } else {
                    merged.append(slice)
                }
            }
        }
        if !buffer.isEmpty { merged.append(buffer) }

        return merged.enumerated().map { (i, content) in
            let lineRange = lineRange(of: content, in: text)
            var meta: [String: String] = ["ext": ext]
            if let range = lineRange { meta["line_range"] = range }
            return (idx: i, content: content,
                    tokenCount: estimateTokens(content), metadata: meta)
        }
    }

    // Markdown: split on heading boundaries (##, ###, ####).
    private func chunkMarkdown(text: String, source: String) -> [ChunkTuple] {
        let lines = text.components(separatedBy: "\n")
        var sections: [String] = []
        var current = ""

        for line in lines {
            if line.hasPrefix("## ") || line.hasPrefix("### ") || line.hasPrefix("#### ") {
                if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    sections.append(current)
                }
                current = line + "\n"
            } else {
                current += line + "\n"
                if estimateTokens(current) >= targetTokens {
                    sections.append(current)
                    current = ""
                }
            }
        }
        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append(current)
        }

        if sections.isEmpty { return chunkSlidingWindow(text: text, source: source) }

        return sections.enumerated().map { (i, content) in
            (idx: i, content: content, tokenCount: estimateTokens(content), metadata: ["type": "markdown"])
        }
    }

    // Sliding window: split by words, overlap at boundaries.
    private func chunkSlidingWindow(text: String, source: String) -> [ChunkTuple] {
        let words = text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
        guard !words.isEmpty else { return [] }

        // Approximate: 1 token ≈ 0.75 words
        let wordsPerChunk = Int(Double(targetTokens) * 0.75)
        let overlapWords = Int(Double(overlapTokens) * 0.75)

        var chunks: [ChunkTuple] = []
        var start = 0
        var idx = 0

        while start < words.count {
            let end = Swift.min(start + wordsPerChunk, words.count)
            let content = words[start..<end].joined(separator: " ")
            chunks.append((idx: idx, content: content,
                           tokenCount: estimateTokens(content), metadata: nil))
            idx += 1
            start = end - overlapWords
            if start <= 0 { start = end }   // guard against infinite loop on very short text
        }

        return chunks
    }

    // MARK: - Helpers

    /// Naive token estimator: 1 token ≈ 4 chars (English text).
    /// Good enough for chunking decisions; not used for billing.
    private func estimateTokens(_ text: String) -> Int {
        max(1, text.count / 4)
    }

    private func corpusFor(ext: String) -> String {
        if Self.codeExtensions.contains(ext) { return "code" }
        if Self.docExtensions.contains(ext) { return "docs" }
        return "docs"
    }

    private func fileMtime(path: String) throws -> Double {
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        return (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
    }

    private func isUpToDate(path: String, mtime: Double) async throws -> Bool {
        try await db.pool.read { db in
            guard let job = try IngestJob
                .filter(Column("source_path") == path)
                .fetchOne(db) else { return false }
            return job.status == "done" &&
                   (job.fileMtime.map { abs($0 - mtime) < 1.0 } ?? false)
        }
    }

    private func markJob(path: String, corpus: String, status: String,
                         mtime: Double, chunkCount: Int = 0,
                         error: String? = nil) async throws {
        try await db.pool.write { db in
            if var existing = try IngestJob
                .filter(Column("source_path") == path).fetchOne(db) {
                existing.status = status
                existing.chunkCount = chunkCount
                existing.fileMtime = mtime
                existing.error = error
                existing.completedAt = (status == "done" || status == "failed") ? Date() : nil
                try existing.update(db)
            } else {
                var job = IngestJob.new(sourcePath: path, corpus: corpus, fileMtime: mtime)
                job.status = status
                job.chunkCount = chunkCount
                job.error = error
                job.completedAt = (status == "done" || status == "failed") ? Date() : nil
                try job.insert(db)
            }
        }
    }

    /// Returns "start_line–end_line" string if content appears in parent text.
    private func lineRange(of content: String, in parent: String) -> String? {
        let parentLines = parent.components(separatedBy: "\n")
        let firstLine = content.components(separatedBy: "\n").first ?? ""
        guard let startIdx = parentLines.firstIndex(where: { $0.contains(firstLine.prefix(40)) })
        else { return nil }
        let lineCount = content.components(separatedBy: "\n").count
        return "\(startIdx + 1)–\(startIdx + lineCount)"
    }
}
