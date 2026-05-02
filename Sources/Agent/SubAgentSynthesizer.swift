import Foundation

// MARK: - Agent definition models

struct AgentDefinition: Codable, Identifiable {
    var id: String { name }
    let name: String           // kebab-case, used as filename
    let description: String    // one-line for SKILL.md frontmatter
    let tools: [String]?       // allowed tool list
    let model: String?         // e.g. "sonnet"
    let bodyMarkdown: String   // system prompt body
    var path: URL?             // written path (not persisted in JSON)

    enum CodingKeys: CodingKey {
        case name, description, tools, model, bodyMarkdown
    }
}

struct SuggestedAgent: Identifiable {
    let id = UUID()
    let name: String
    let description: String
    let allowedTools: [String]
    let model: String?
    let systemPromptDraft: String
    let basedOnTaskSummaries: [String]
}

// MARK: - SubAgentSynthesizer

/// Detects recurring task patterns in past approvals/code tasks and offers
/// to write ~/.claude/agents/<name>.md definition files.
@MainActor
final class SubAgentSynthesizer: ObservableObject {

    @Published private(set) var suggestions: [SuggestedAgent] = []
    @Published private(set) var writtenAgents: [AgentDefinition] = []
    @Published var isAnalyzing = false

    weak var appState: AppState?

    // MARK: - Suggest

    /// Analyzes recent task summaries and returns suggested agent definitions.
    func suggestAgents(lastN: Int = 30) async {
        guard let appState, let coordinator = appState.agentCoordinator else { return }
        isAnalyzing = true
        defer { isAnalyzing = false }

        // Gather recent task descriptions from audit log + coding orchestrator
        var taskSummaries: [String] = []

        // From audit log (tool names + justifications)
        let approvals = await appState.consentGate?.recentApprovals(limit: lastN) ?? []
        for a in approvals {
            let summary = "[\(a.toolName)] \(a.justification ?? "")"
            if !summary.isEmpty { taskSummaries.append(summary) }
        }

        // From conversation messages (user turns)
        let userMessages = appState.conversationMessages
            .filter { $0.role == .user }
            .suffix(lastN)
            .map(\.content)
        taskSummaries.append(contentsOf: userMessages)

        guard !taskSummaries.isEmpty else { return }

        let prompt = """
You are an AI assistant helping to detect recurring patterns in a developer's task history.
Analyze these \(taskSummaries.count) recent task descriptions and identify 1-3 reusable
subagent definitions that could automate common workflows.

Tasks:
\(taskSummaries.prefix(30).enumerated().map { "\($0.offset+1). \($0.element)" }.joined(separator: "\n"))

For each suggested agent, output JSON in this exact format (array):
[
  {
    "name": "kebab-case-name",
    "description": "one-line description used for agent activation",
    "tools": ["Read", "Edit", "Bash"],
    "model": "sonnet",
    "systemPromptDraft": "detailed system prompt..."
  }
]

Only suggest agents for patterns that appear at least 2-3 times.
If no clear patterns exist, return an empty array [].
Output ONLY the JSON array, no other text.
"""

        do {
            let result = try await coordinator.run(query: prompt)
            // Extract JSON array from result
            guard let start = result.firstIndex(of: "["),
                  let end   = result.lastIndex(of: "]") else { return }
            let jsonStr = String(result[start...end])
            guard let data = jsonStr.data(using: .utf8),
                  let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
            else { return }

            suggestions = raw.compactMap { d -> SuggestedAgent? in
                guard let name = d["name"] as? String,
                      let desc = d["description"] as? String,
                      let body = d["systemPromptDraft"] as? String else { return nil }
                let tools = d["tools"] as? [String] ?? ["Read", "Edit"]
                let model = d["model"] as? String
                return SuggestedAgent(
                    name:                 name,
                    description:          desc,
                    allowedTools:         tools,
                    model:                model,
                    systemPromptDraft:    body,
                    basedOnTaskSummaries: Array(taskSummaries.prefix(5))
                )
            }
        } catch {
            appState.logError(source: "SubAgentSynthesizer", message: error.localizedDescription)
        }
    }

    // MARK: - Write agent file

    enum Scope { case user, project(URL) }

    func writeAgent(_ suggestion: SuggestedAgent, scope: Scope) async throws {
        let dir: URL
        switch scope {
        case .user:
            dir = URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent(".claude/agents")
        case .project(let root):
            dir = root.appendingPathComponent(".claude/agents")
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let toolsYAML = suggestion.allowedTools.map { "\"\($0)\"" }.joined(separator: ", ")
        let modelLine = suggestion.model.map { "\nmodel: \($0)" } ?? ""
        let content = """
---
name: \(suggestion.name)
description: \(suggestion.description)
tools: [\(toolsYAML)]\(modelLine)
---

\(suggestion.systemPromptDraft)
"""

        let fileURL = dir.appendingPathComponent("\(suggestion.name).md")
        try content.write(to: fileURL, atomically: true, encoding: .utf8)

        let def = AgentDefinition(
            name:           suggestion.name,
            description:    suggestion.description,
            tools:          suggestion.allowedTools,
            model:          suggestion.model,
            bodyMarkdown:   suggestion.systemPromptDraft,
            path:           fileURL
        )
        writtenAgents.append(def)
        print("[SubAgentSynthesizer] wrote \(fileURL.path)")
    }

    // MARK: - List existing agents

    func listAgents(scope: Scope = .user) async throws -> [AgentDefinition] {
        let dir: URL
        switch scope {
        case .user:
            dir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/agents")
        case .project(let root):
            dir = root.appendingPathComponent(".claude/agents")
        }
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        else { return [] }

        var result: [AgentDefinition] = []
        for item in items where item.pathExtension == "md" {
            guard let content = try? String(contentsOf: item, encoding: .utf8) else { continue }
            // Parse frontmatter
            let lines = content.components(separatedBy: "\n")
            var name = item.deletingPathExtension().lastPathComponent
            var description = ""
            var tools: [String]? = nil
            var model: String? = nil
            var inFrontmatter = false
            var bodyLines: [String] = []
            var pastFrontmatter = false
            var fmCount = 0
            for line in lines {
                if line.trimmingCharacters(in: .whitespaces) == "---" {
                    fmCount += 1
                    inFrontmatter = fmCount == 1
                    if fmCount == 2 { inFrontmatter = false; pastFrontmatter = true }
                    continue
                }
                if inFrontmatter {
                    if line.hasPrefix("name:") { name = line.dropFirst(5).trimmingCharacters(in: .whitespaces) }
                    if line.hasPrefix("description:") { description = line.dropFirst(12).trimmingCharacters(in: .whitespaces) }
                    if line.hasPrefix("model:") { model = line.dropFirst(6).trimmingCharacters(in: .whitespaces) }
                    // [A10-fix] Parse tools array: tools: ["Read", "Edit", "Bash"]
                    if line.hasPrefix("tools:") {
                        let raw = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
                        let stripped = raw.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                        let parsed = stripped.components(separatedBy: ",")
                            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"'")) }
                            .filter { !$0.isEmpty }
                        if !parsed.isEmpty { tools = parsed }
                    }
                } else if pastFrontmatter {
                    bodyLines.append(line)
                }
            }
            result.append(AgentDefinition(
                name:         name,
                description:  description,
                tools:        tools,
                model:        model,
                bodyMarkdown: bodyLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines),
                path:         item
            ))
        }
        return result
    }
}
