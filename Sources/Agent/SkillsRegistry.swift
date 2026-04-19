import Foundation

// MARK: - SkillsRegistry
//
// Loads all skill definitions from ~/.shiro/skills/*.json.
// Skills are callable behaviours the agent (or user via slash command) can invoke.
//
// Directory is created with built-in defaults on first launch.
// Shiromi (or the user) can drop new .json files in there at any time;
// call reload() to pick them up without restarting the app.

@MainActor
final class SkillsRegistry: ObservableObject {

    // MARK: - Model

    struct SkillParameter: Codable {
        var name: String
        var description: String
        var required: Bool
        var defaultValue: String?

        enum CodingKeys: String, CodingKey {
            case name, description, required
            case defaultValue = "default"
        }
    }

    struct Skill: Codable, Identifiable {
        var id: String { name }
        var name: String                          // "research"
        var description: String
        var trigger: String                       // "/research"
        var systemPrompt: String
        var promptTemplate: String                // "Research: {{topic}}"
        var parameters: [SkillParameter]
        var model: String?                        // nil → use default
        var maxTurns: Int?
        var allowedTools: [String]?               // nil → all tools
        var enabled: Bool

        /// Fill {{param}} placeholders from a dict.
        func fillTemplate(args: [String: String]) -> String {
            var result = promptTemplate
            for (key, value) in args {
                result = result.replacingOccurrences(of: "{{\(key)}}", with: value)
            }
            return result
        }

        /// Parse a raw argument string into named params.
        /// For single-param skills the whole string becomes the first param.
        func parseArgs(_ raw: String) -> [String: String] {
            guard !parameters.isEmpty else { return [:] }
            if parameters.count == 1 {
                return [parameters[0].name: raw.trimmingCharacters(in: .whitespacesAndNewlines)]
            }
            // Multi-param: expect "key=value key2=value2" format.
            var result: [String: String] = [:]
            let tokens = raw.components(separatedBy: " ")
            for token in tokens {
                let parts = token.split(separator: "=", maxSplits: 1).map(String.init)
                if parts.count == 2 { result[parts[0]] = parts[1] }
            }
            // Fill in defaults for missing required params.
            for param in parameters {
                if result[param.name] == nil, let def = param.defaultValue {
                    result[param.name] = def
                }
            }
            return result
        }
    }

    // MARK: - State

    @Published private(set) var skills: [Skill] = []

    // MARK: - Paths

    static var skillsDir: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".shiro/skills", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Init

    init() {
        writeDefaultsIfNeeded()
        load()
    }

    // MARK: - Load

    func load() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: Self.skillsDir,
            includingPropertiesForKeys: nil
        ) else { return }

        let decoder = JSONDecoder()
        var loaded: [Skill] = []

        for file in files where file.pathExtension == "json" {
            do {
                let data = try Data(contentsOf: file)
                let skill = try decoder.decode(Skill.self, from: data)
                loaded.append(skill)
            } catch {
                print("[SkillsRegistry] failed to load \(file.lastPathComponent): \(error.localizedDescription)")
            }
        }

        skills = loaded.sorted { $0.name < $1.name }
        print("[SkillsRegistry] loaded \(skills.count) skills")
    }

    // MARK: - Lookup

    /// Find a skill by exact name.
    func skill(named name: String) -> Skill? {
        skills.first { $0.name == name }
    }

    /// Find a skill by slash trigger (e.g. "/research").
    func skill(forTrigger trigger: String) -> Skill? {
        let normalised = trigger.hasPrefix("/") ? trigger : "/" + trigger
        return skills.first { $0.trigger == normalised && $0.enabled }
    }

    /// Parse a user input string into a (skill, filledPrompt) pair.
    /// Returns nil if input doesn't start with a known trigger.
    func resolve(input: String) -> (skill: Skill, prompt: String)? {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("/") else { return nil }

        let parts = trimmed.split(separator: " ", maxSplits: 1).map(String.init)
        let trigger = parts[0]
        let rawArgs = parts.count > 1 ? parts[1] : ""

        guard let skill = skill(forTrigger: trigger) else { return nil }
        let args = skill.parseArgs(rawArgs)
        let prompt = skill.fillTemplate(args: args)
        return (skill, prompt)
    }

    // MARK: - Built-in defaults

    private func writeDefaultsIfNeeded() {
        // Only write defaults if the directory is empty
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(atPath: Self.skillsDir.path)) ?? []
        guard files.filter({ $0.hasSuffix(".json") }).isEmpty else { return }

        let defaults: [Skill] = [
            Skill(
                name: "research",
                description: "Deep research on any topic — memory search + knowledge graph synthesis",
                trigger: "/research",
                systemPrompt: """
                    You are Shiro's research mode. Your job is to thoroughly research the given topic.
                    Use search_memory to find relevant local context, query_kg for known entities,
                    and synthesise everything into a clear, structured report.
                    Always cite your sources (file paths, session IDs, or knowledge graph nodes).
                    Be direct. No padding. Lead with the most important findings.
                    """,
                promptTemplate: "Research the following topic thoroughly:\n\n{{topic}}\n\nProvide: executive summary, key findings, gaps in knowledge, and recommended next steps.",
                parameters: [
                    SkillParameter(name: "topic", description: "What to research", required: true, defaultValue: nil)
                ],
                model: nil,
                maxTurns: 6,
                allowedTools: ["search_memory", "query_kg", "execute_sql", "file_read"],
                enabled: true
            ),
            Skill(
                name: "summarise-meeting",
                description: "Extract action items and key decisions from a meeting transcript",
                trigger: "/summarise-meeting",
                systemPrompt: """
                    You are Shiro's meeting summariser. Extract maximum signal from transcripts with zero noise.
                    Format output exactly as:
                    ## Summary (2-3 sentences)
                    ## Decisions Made (bullet list)
                    ## Action Items (bullet list with owner and deadline if mentioned)
                    ## Open Questions (bullet list)
                    """,
                promptTemplate: "Summarise this meeting transcript:\n\n{{transcript}}",
                parameters: [
                    SkillParameter(name: "transcript", description: "Raw meeting transcript text", required: true, defaultValue: nil)
                ],
                model: nil,
                maxTurns: 2,
                allowedTools: ["execute_sql", "query_kg"],
                enabled: true
            ),
            Skill(
                name: "code-review",
                description: "Review code files for bugs, security issues, and quality problems",
                trigger: "/review",
                systemPrompt: """
                    You are Shiro's code reviewer. Be surgical and direct.
                    Check for: security vulnerabilities, logic bugs, missing error handling,
                    N+1 queries, race conditions, missing types, dead code, naming issues.
                    Report as numbered list with exact file:line for each issue.
                    Severity: CRITICAL / HIGH / MEDIUM / LOW.
                    Never mention formatting — linters handle that.
                    """,
                promptTemplate: "Review this code for issues:\n\n{{target}}\n\nFocus on correctness, security, and performance. Skip style.",
                parameters: [
                    SkillParameter(name: "target", description: "File path or code to review", required: true, defaultValue: nil)
                ],
                model: nil,
                maxTurns: 4,
                allowedTools: ["file_read", "search_memory", "query_kg"],
                enabled: true
            ),
            Skill(
                name: "draft-email",
                description: "Draft a professional email based on intent and context",
                trigger: "/email",
                systemPrompt: """
                    You are Shiro's email drafter. Write clear, professional emails.
                    Tone: direct but warm. No corporate fluff. No "I hope this email finds you well."
                    Match the requested tone (formal/casual) when specified.
                    Output the email only — subject line first, then body.
                    """,
                promptTemplate: "Draft an email:\n\nTo: {{to}}\nIntent: {{intent}}\n\nTone: {{tone}}",
                parameters: [
                    SkillParameter(name: "to", description: "Recipient name or role", required: true, defaultValue: nil),
                    SkillParameter(name: "intent", description: "What the email should accomplish", required: true, defaultValue: nil),
                    SkillParameter(name: "tone", description: "formal or casual", required: false, defaultValue: "professional")
                ],
                model: nil,
                maxTurns: 2,
                allowedTools: ["query_kg"],
                enabled: true
            ),
            Skill(
                name: "daily-brief",
                description: "Morning briefing: open tasks, recent memory, and agenda",
                trigger: "/brief",
                systemPrompt: """
                    You are Shiro's morning briefing mode. Pull together:
                    1. All tasks with status 'in_progress' or 'todo' ordered by priority
                    2. Recent KG updates from the last 24h
                    3. Any pending tool approvals
                    4. A suggested focus for the day (single sentence)
                    Be concise. The user is starting their day — give them signal, not noise.
                    """,
                promptTemplate: "Generate my daily brief. Today is {{date}}. {{context}}",
                parameters: [
                    SkillParameter(name: "date", description: "Today's date", required: true, defaultValue: nil),
                    SkillParameter(name: "context", description: "Optional additional context", required: false, defaultValue: "")
                ],
                model: nil,
                maxTurns: 3,
                allowedTools: ["execute_sql", "query_kg", "search_memory"],
                enabled: true
            ),
            Skill(
                name: "ingest",
                description: "Index a file or directory into Shiro's memory",
                trigger: "/ingest",
                systemPrompt: """
                    You are Shiro's memory ingestion mode.
                    The user wants to add content to your long-term memory.
                    Confirm what was indexed and how many chunks were created.
                    If something failed, explain why clearly.
                    """,
                promptTemplate: "Ingest the following into memory:\n\n{{path}}\n\nCorpus: {{corpus}}",
                parameters: [
                    SkillParameter(name: "path", description: "File or directory path", required: true, defaultValue: nil),
                    SkillParameter(name: "corpus", description: "Memory corpus to use", required: false, defaultValue: "docs")
                ],
                model: nil,
                maxTurns: 2,
                allowedTools: ["file_read", "execute_sql"],
                enabled: true
            ),
        ]

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        for skill in defaults {
            let url = Self.skillsDir.appendingPathComponent("\(skill.name).json")
            do {
                let data = try encoder.encode(skill)
                try data.write(to: url, options: .atomic)
            } catch {
                print("[SkillsRegistry] failed to write default skill \(skill.name): \(error.localizedDescription)")
            }
        }
        print("[SkillsRegistry] wrote \(defaults.count) default skills to \(Self.skillsDir.path)")
    }
}
