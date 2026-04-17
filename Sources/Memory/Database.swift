import Foundation
import GRDB

/// Single SQLite database for all Shiro state.
/// One file: ~/Library/Application Support/Shiro/shiro.db
final class ShiroDatabase {
    let pool: DatabasePool

    init() throws {
        self.pool = try DatabasePool(path: Config.databasePath.path)
        try migrate()
        print("[DB] ✅ Opened at \(Config.databasePath.path)")
    }

    // MARK: - Migrations

    private func migrate() throws {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_initial") { db in
            // ── Knowledge Graph ──────────────────────────────────────────
            try db.create(table: "kg_nodes", ifNotExists: true) { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("type", .text).notNull()        // person, project, concept, tool, file, meeting
                t.column("summary", .text)
                t.column("attributes", .text)            // JSON dict
                t.column("embedding", .blob)             // float32 array, 768 dims
                t.column("created_at", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
                t.column("updated_at", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
            }

            try db.create(table: "kg_edges", ifNotExists: true) { t in
                t.primaryKey("id", .text)
                t.column("source_id", .text).notNull().references("kg_nodes", onDelete: .cascade)
                t.column("target_id", .text).notNull().references("kg_nodes", onDelete: .cascade)
                t.column("relationship", .text).notNull() // works_on, uses, knows, related_to, created, attended
                t.column("fact", .text)                   // "Abhishek is building Shiro"
                t.column("confidence", .double).notNull().defaults(to: 1.0)
                t.column("created_at", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
            }
            try db.create(indexOn: "kg_edges", columns: ["source_id"])
            try db.create(indexOn: "kg_edges", columns: ["target_id"])

            // ── Tasks ────────────────────────────────────────────────────
            try db.create(table: "tasks", ifNotExists: true) { t in
                t.primaryKey("id", .text)
                t.column("title", .text).notNull()
                t.column("description", .text)
                t.column("status", .text).notNull().defaults(to: "backlog")
                // backlog | todo | in_progress | done | cancelled
                t.column("priority", .text).notNull().defaults(to: "medium")
                // low | medium | high | urgent
                t.column("source", .text).notNull().defaults(to: "user")
                // user | meeting | screen | sub_agent | file_watch
                t.column("parent_task_id", .text).references("tasks")
                t.column("assigned_agent", .text)         // "main" | "sub_1" | "sub_2" etc
                t.column("context_json", .text)           // JSON: relevant KG node IDs, conversation refs
                t.column("result", .text)                 // final result once done
                t.column("started_at", .datetime)
                t.column("completed_at", .datetime)
                t.column("created_at", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
                t.column("updated_at", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
            }
            try db.create(indexOn: "tasks", columns: ["status"])
            try db.create(indexOn: "tasks", columns: ["parent_task_id"])

            try db.create(table: "task_runs", ifNotExists: true) { t in
                t.primaryKey("id", .text)
                t.column("task_id", .text).notNull().references("tasks", onDelete: .cascade)
                t.column("agent", .text).notNull()
                t.column("status", .text).notNull().defaults(to: "running")
                // running | succeeded | failed | timed_out
                t.column("input_tokens", .integer).notNull().defaults(to: 0)
                t.column("output_tokens", .integer).notNull().defaults(to: 0)
                t.column("tool_calls_json", .text)        // JSON array of tool invocations
                t.column("result", .text)
                t.column("error", .text)
                t.column("started_at", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
                t.column("completed_at", .datetime)
            }

            // ── Observations (perception layer) ──────────────────────────
            try db.create(table: "observations", ifNotExists: true) { t in
                t.primaryKey("id", .text)
                t.column("type", .text).notNull()        // screen | audio | file_change | browser
                t.column("data_json", .text).notNull()   // structured payload
                t.column("processed", .boolean).notNull().defaults(to: false)
                t.column("kg_updates_json", .text)       // what changed in KG from this observation
                t.column("created_at", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
            }
            try db.create(indexOn: "observations", columns: ["type", "processed"])
            try db.create(indexOn: "observations", columns: ["created_at"])

            // ── Conversations ────────────────────────────────────────────
            try db.create(table: "conversations", ifNotExists: true) { t in
                t.primaryKey("id", .text)
                t.column("session_id", .text).notNull()
                t.column("role", .text).notNull()        // user | assistant | system | tool
                t.column("content", .text).notNull()
                t.column("tool_calls_json", .text)
                t.column("tool_results_json", .text)
                t.column("model", .text)
                t.column("input_tokens", .integer).notNull().defaults(to: 0)
                t.column("output_tokens", .integer).notNull().defaults(to: 0)
                t.column("created_at", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
            }
            try db.create(indexOn: "conversations", columns: ["session_id"])

            // ── Indexed Files ────────────────────────────────────────────
            try db.create(table: "indexed_files", ifNotExists: true) { t in
                t.primaryKey("id", .text)
                t.column("path", .text).notNull().unique()
                t.column("name", .text).notNull()
                t.column("extension", .text)
                t.column("size_bytes", .integer)
                t.column("file_type", .text)             // code | document | image | data | other
                t.column("summary", .text)
                t.column("embedding", .blob)
                t.column("kg_node_id", .text).references("kg_nodes")
                t.column("last_modified", .datetime)
                t.column("indexed_at", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
            }

            // ── Meeting Transcripts ───────────────────────────────────────
            try db.create(table: "meeting_sessions", ifNotExists: true) { t in
                t.primaryKey("id", .text)
                t.column("title", .text)
                t.column("full_transcript", .text)
                t.column("summary", .text)
                t.column("action_items_json", .text)     // JSON array of extracted action items
                t.column("participants_json", .text)     // JSON array of names if detected
                t.column("started_at", .datetime).notNull()
                t.column("ended_at", .datetime)
                t.column("created_at", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
            }
        }

        try migrator.migrate(pool)
        print("[DB] ✅ Migrations complete")
    }
}

// MARK: - GRDB Record Types

struct KGNode: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "kg_nodes"
    var id: String
    var name: String
    var type: String
    var summary: String?
    var attributesJSON: String?
    var embedding: Data?
    var createdAt: Date
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, name, type, summary
        case attributesJSON = "attributes"
        case embedding
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    var attributes: [String: String] {
        get {
            guard let json = attributesJSON,
                  let data = json.data(using: .utf8),
                  let dict = try? JSONDecoder().decode([String: String].self, from: data)
            else { return [:] }
            return dict
        }
    }

    static func new(name: String, type: String, summary: String? = nil) -> KGNode {
        KGNode(
            id: UUID().uuidString,
            name: name,
            type: type,
            summary: summary,
            attributesJSON: nil,
            embedding: nil,
            createdAt: Date(),
            updatedAt: Date()
        )
    }
}

struct KGEdge: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "kg_edges"
    var id: String
    var sourceId: String
    var targetId: String
    var relationship: String
    var fact: String?
    var confidence: Double
    var createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case sourceId = "source_id"
        case targetId = "target_id"
        case relationship, fact, confidence
        case createdAt = "created_at"
    }

    static func new(from sourceId: String, to targetId: String, relationship: String, fact: String? = nil) -> KGEdge {
        KGEdge(id: UUID().uuidString, sourceId: sourceId, targetId: targetId,
               relationship: relationship, fact: fact, confidence: 1.0, createdAt: Date())
    }
}

struct ShiroTask: Codable, FetchableRecord, PersistableRecord, Identifiable {
    static let databaseTableName = "tasks"
    var id: String
    var title: String
    var description: String?
    var status: String          // backlog | todo | in_progress | done | cancelled
    var priority: String        // low | medium | high | urgent
    var source: String          // user | meeting | screen | sub_agent | file_watch
    var parentTaskId: String?
    var assignedAgent: String?
    var contextJSON: String?
    var result: String?
    var startedAt: Date?
    var completedAt: Date?
    var createdAt: Date
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, title, description, status, priority, source, result
        case parentTaskId = "parent_task_id"
        case assignedAgent = "assigned_agent"
        case contextJSON = "context_json"
        case startedAt = "started_at"
        case completedAt = "completed_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    static func new(title: String, description: String? = nil, source: String = "user", priority: String = "medium") -> ShiroTask {
        ShiroTask(
            id: UUID().uuidString,
            title: title,
            description: description,
            status: "backlog",
            priority: priority,
            source: source,
            parentTaskId: nil,
            assignedAgent: nil,
            contextJSON: nil,
            result: nil,
            startedAt: nil,
            completedAt: nil,
            createdAt: Date(),
            updatedAt: Date()
        )
    }
}

struct Observation: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "observations"
    var id: String
    var type: String            // screen | audio | file_change | browser
    var dataJSON: String
    var processed: Bool
    var kgUpdatesJSON: String?
    var createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, type, processed
        case dataJSON = "data_json"
        case kgUpdatesJSON = "kg_updates_json"
        case createdAt = "created_at"
    }

    static func new(type: String, data: [String: Any]) -> Observation {
        let json = (try? JSONSerialization.data(withJSONObject: data))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return Observation(id: UUID().uuidString, type: type, dataJSON: json,
                           processed: false, kgUpdatesJSON: nil, createdAt: Date())
    }
}

struct ConversationMessage: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "conversations"
    var id: String
    var sessionId: String
    var role: String            // user | assistant | system | tool
    var content: String
    var toolCallsJSON: String?
    var toolResultsJSON: String?
    var model: String?
    var inputTokens: Int
    var outputTokens: Int
    var createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, role, content, model
        case sessionId = "session_id"
        case toolCallsJSON = "tool_calls_json"
        case toolResultsJSON = "tool_results_json"
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case createdAt = "created_at"
    }

    static func new(sessionId: String, role: String, content: String, model: String? = nil) -> ConversationMessage {
        ConversationMessage(id: UUID().uuidString, sessionId: sessionId, role: role,
                            content: content, toolCallsJSON: nil, toolResultsJSON: nil,
                            model: model, inputTokens: 0, outputTokens: 0, createdAt: Date())
    }
}

struct MeetingSession: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "meeting_sessions"
    var id: String
    var title: String?
    var fullTranscript: String?
    var summary: String?
    var actionItemsJSON: String?
    var participantsJSON: String?
    var startedAt: Date
    var endedAt: Date?
    var createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, title, summary
        case fullTranscript = "full_transcript"
        case actionItemsJSON = "action_items_json"
        case participantsJSON = "participants_json"
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case createdAt = "created_at"
    }
}
