import Foundation
import GRDB

/// All knowledge graph operations: create nodes, link edges, semantic search.
final class KnowledgeGraphService {
    private let database: ShiroDatabase
    private let lmStudio: LMStudioClient

    init(database: ShiroDatabase, lmStudio: LMStudioClient) {
        self.database = database
        self.lmStudio = lmStudio
    }

    // MARK: - Node Operations

    func upsertNode(name: String, type: String, summary: String? = nil, attributes: [String: String] = [:]) async throws -> KGNode {
        // Check if node with this name+type already exists
        if let existing = try await database.pool.read({ db in
            try KGNode.filter(Column("name") == name && Column("type") == type).fetchOne(db)
        }) {
            // Update summary if provided
            if let summary, summary != existing.summary {
                var updated = existing
                updated.summary = summary
                try await database.pool.write { db in try updated.update(db) }
                return updated
            }
            return existing
        }

        // Create new node
        var node = KGNode.new(name: name, type: type, summary: summary)
        if !attributes.isEmpty {
            let data = try JSONEncoder().encode(attributes)
            node.attributesJSON = String(data: data, encoding: .utf8)
        }

        // Generate embedding
        let textToEmbed = [name, type, summary].compactMap { $0 }.joined(separator: " ")
        if let embedding = try? await lmStudio.embed(text: textToEmbed) {
            node.embedding = floatsToData(embedding)
        }

        try await database.pool.write { db in try node.insert(db) }
        print("[KG] ➕ Node: \(name) (\(type))")
        return node
    }

    func addEdge(from sourceName: String, sourceType: String,
                 to targetName: String, targetType: String,
                 relationship: String, fact: String? = nil) async throws {
        let source = try await upsertNode(name: sourceName, type: sourceType)
        let target = try await upsertNode(name: targetName, type: targetType)

        // Check if edge already exists
        let exists = try await database.pool.read { db in
            try KGEdge
                .filter(Column("source_id") == source.id &&
                        Column("target_id") == target.id &&
                        Column("relationship") == relationship)
                .fetchOne(db) != nil
        }
        guard !exists else { return }

        let edge = KGEdge.new(from: source.id, to: target.id, relationship: relationship, fact: fact)
        try await database.pool.write { db in try edge.insert(db) }
        print("[KG] 🔗 \(sourceName) --[\(relationship)]--> \(targetName)")
    }

    // MARK: - Semantic Search

    /// Find nodes semantically similar to a query string.
    func search(query: String, limit: Int = 5) async throws -> [KGNode] {
        guard let queryEmbedding = try? await lmStudio.embed(text: query) else {
            // Fallback: text search
            return try await textSearch(query: query, limit: limit)
        }

        let allNodes = try await database.pool.read { db in
            try KGNode.filter(Column("embedding") != nil).fetchAll(db)
        }

        // Cosine similarity ranking
        let scored: [(KGNode, Float)] = allNodes.compactMap { node in
            guard let data = node.embedding else { return nil }
            let nodeEmbedding = dataToFloats(data)
            let similarity = cosineSimilarity(queryEmbedding, nodeEmbedding)
            return (node, similarity)
        }

        return scored
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map { $0.0 }
    }

    func textSearch(query: String, limit: Int = 5) async throws -> [KGNode] {
        try await database.pool.read { db in
            try KGNode
                .filter(Column("name").like("%\(query)%") ||
                        Column("summary").like("%\(query)%"))
                .limit(limit)
                .fetchAll(db)
        }
    }

    // MARK: - Context Retrieval

    /// Get all edges for a node (its relationships).
    func edges(for nodeId: String) async throws -> [KGEdge] {
        try await database.pool.read { db in
            try KGEdge
                .filter(Column("source_id") == nodeId || Column("target_id") == nodeId)
                .fetchAll(db)
        }
    }

    /// Build a context string for the agent about a given topic.
    func buildContext(topic: String) async throws -> String {
        let nodes = try await search(query: topic, limit: 8)
        guard !nodes.isEmpty else { return "No relevant context found for: \(topic)" }

        var lines: [String] = ["## Knowledge Graph Context for: \(topic)\n"]
        for node in nodes {
            lines.append("**\(node.name)** [\(node.type)]")
            if let summary = node.summary { lines.append("  → \(summary)") }

            let nodeEdges = try await edges(for: node.id)
            for edge in nodeEdges.prefix(3) {
                if let fact = edge.fact {
                    lines.append("  • \(fact)")
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Auto-Extract from Text

    /// Ask LLM to extract entities + relationships from a text and add to KG.
    func extractAndStore(text: String, source: String = "observation") async throws {
        let prompt = """
        Extract entities and relationships from this text. Return JSON only.
        {
          "entities": [
            {"name": "...", "type": "person|project|concept|tool|file|meeting", "summary": "..."}
          ],
          "relationships": [
            {"from": "...", "from_type": "...", "to": "...", "to_type": "...", "relationship": "works_on|uses|knows|created|attended|related_to", "fact": "plain english description"}
          ]
        }
        Text: \(text.prefix(2000))
        """

        let response = try await lmStudio.fast(prompt: prompt, maxTokens: 1024)

        struct Extraction: Decodable {
            struct Entity: Decodable { let name: String; let type: String; let summary: String? }
            struct Relationship: Decodable {
                let from: String; let from_type: String
                let to: String; let to_type: String
                let relationship: String; let fact: String?
            }
            let entities: [Entity]
            let relationships: [Relationship]
        }

        // Extract JSON from response
        guard let start = response.range(of: "{"),
              let end = response.range(of: "}", options: .backwards) else { return }
        let jsonStr = String(response[start.lowerBound...end.upperBound])
        guard let data = jsonStr.data(using: .utf8),
              let extraction = try? JSONDecoder().decode(Extraction.self, from: data) else { return }

        for entity in extraction.entities {
            _ = try await upsertNode(name: entity.name, type: entity.type, summary: entity.summary)
        }
        for rel in extraction.relationships {
            try await addEdge(
                from: rel.from, sourceType: rel.from_type,
                to: rel.to, targetType: rel.to_type,
                relationship: rel.relationship,
                fact: rel.fact
            )
        }

        print("[KG] 📖 Extracted from \(source): \(extraction.entities.count) entities, \(extraction.relationships.count) relationships")
    }

    // MARK: - Vector Math

    private func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        let dot = zip(a, b).reduce(0, { $0 + $1.0 * $1.1 })
        let magA = sqrt(a.reduce(0, { $0 + $1 * $1 }))
        let magB = sqrt(b.reduce(0, { $0 + $1 * $1 }))
        guard magA > 0, magB > 0 else { return 0 }
        return dot / (magA * magB)
    }

    private func floatsToData(_ floats: [Float]) -> Data {
        floats.withUnsafeBytes { Data($0) }
    }

    private func dataToFloats(_ data: Data) -> [Float] {
        data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
}
