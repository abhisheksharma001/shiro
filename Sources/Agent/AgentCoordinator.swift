import Foundation
import GRDB

// MARK: - Tool Definition Registry

extension AgentCoordinator {
    static let coreTools: [ToolDefinition] = [
        ToolDefinition(function: .init(
            name: "shell",
            description: "Run a shell command and return stdout/stderr",
            parameters: JSONSchema(type: "object",
                properties: ["command": .init(type: "string", description: "The shell command to run", enumValues: nil)],
                required: ["command"])
        )),
        ToolDefinition(function: .init(
            name: "read_file",
            description: "Read the contents of a file at a given path",
            parameters: JSONSchema(type: "object",
                properties: ["path": .init(type: "string", description: "Absolute or ~ path to file", enumValues: nil)],
                required: ["path"])
        )),
        ToolDefinition(function: .init(
            name: "write_file",
            description: "Write content to a file (creates or overwrites)",
            parameters: JSONSchema(type: "object",
                properties: [
                    "path": .init(type: "string", description: "File path", enumValues: nil),
                    "content": .init(type: "string", description: "Content to write", enumValues: nil)
                ],
                required: ["path", "content"])
        )),
        ToolDefinition(function: .init(
            name: "search_knowledge_graph",
            description: "Search Shiro's local knowledge graph for context about a topic",
            parameters: JSONSchema(type: "object",
                properties: ["query": .init(type: "string", description: "What to search for", enumValues: nil)],
                required: ["query"])
        )),
        ToolDefinition(function: .init(
            name: "create_task",
            description: "Create a new task for Shiro to work on later",
            parameters: JSONSchema(type: "object",
                properties: [
                    "title": .init(type: "string", description: "Short task title", enumValues: nil),
                    "description": .init(type: "string", description: "Detailed description", enumValues: nil),
                    "priority": .init(type: "string", description: "Priority level", enumValues: ["low", "medium", "high", "urgent"])
                ],
                required: ["title"])
        )),
        ToolDefinition(function: .init(
            name: "web_search",
            description: "Search the web using DuckDuckGo and return top results",
            parameters: JSONSchema(type: "object",
                properties: ["query": .init(type: "string", description: "Search query", enumValues: nil)],
                required: ["query"])
        )),
        ToolDefinition(function: .init(
            name: "get_screen_context",
            description: "Get the latest screen observation — what's currently on screen",
            parameters: JSONSchema(type: "object", properties: [:], required: [])
        )),
        ToolDefinition(function: .init(
            name: "spawn_sub_agent",
            description: "Delegate a sub-task to a parallel sub-agent and wait for result",
            parameters: JSONSchema(type: "object",
                properties: [
                    "task_title": .init(type: "string", description: "Title of the sub-task", enumValues: nil),
                    "task_description": .init(type: "string", description: "Full description of what the sub-agent should do", enumValues: nil)
                ],
                required: ["task_title", "task_description"])
        )),
    ]
}

// MARK: - AgentCoordinator (ReACT Loop)

@MainActor
final class AgentCoordinator: ObservableObject {

    private let database: ShiroDatabase
    private let lmStudio: LMStudioClient
    private let knowledgeGraph: KnowledgeGraphService

    @Published var isRunning: Bool = false
    @Published var currentTaskTitle: String = ""
    @Published var iterationCount: Int = 0

    var onStatusUpdate: ((String) -> Void)?

    private let systemPrompt = """
    You are Shiro, a proactive AI desktop agent running locally on Abhishek's Mac.
    You have access to his screen, files, knowledge graph, and can run shell commands.

    Your personality:
    - Proactive: you notice things and act without being asked
    - Concise: short responses, no fluff
    - Precise: use exact file paths, line numbers, tool names
    - Honest: say "I don't know" rather than guessing

    Available tools: shell, read_file, write_file, search_knowledge_graph,
                     create_task, web_search, get_screen_context, spawn_sub_agent

    When working:
    1. Think step by step before acting
    2. Use tools to gather info before making changes
    3. Verify results after each tool call
    4. Create sub-tasks for things you can't do right now
    5. Update the knowledge graph with anything important you learn

    Current date: \(ISO8601DateFormatter().string(from: Date()))
    """

    init(database: ShiroDatabase, lmStudio: LMStudioClient, knowledgeGraph: KnowledgeGraphService) {
        self.database = database
        self.lmStudio = lmStudio
        self.knowledgeGraph = knowledgeGraph
    }

    // MARK: - Main Entry Point

    /// Run a user query through the full ReACT loop.
    func run(query: String, sessionId: String = UUID().uuidString) async throws -> String {
        isRunning = true
        currentTaskTitle = query.prefix(60).description
        iterationCount = 0
        defer { isRunning = false }

        var messages: [ChatMessage] = [
            ChatMessage(role: "system", text: systemPrompt)
        ]

        // Inject knowledge graph context
        if let context = try? await knowledgeGraph.buildContext(topic: query), !context.isEmpty {
            messages.append(ChatMessage(role: "system", text: context))
        }

        messages.append(ChatMessage(role: "user", text: query))

        // Save user message
        let userMsg = ConversationMessage.new(sessionId: sessionId, role: "user", content: query)
        try? await database.pool.write { db in try userMsg.insert(db) }

        // ReACT loop
        var finalResponse = ""
        for iteration in 0..<Config.maxAgentIterations {
            iterationCount = iteration + 1
            onStatusUpdate?("Thinking… (step \(iterationCount))")

            let model = ModelRouter.route(prompt: query, tools: AgentCoordinator.coreTools)
            let response = try await lmStudio.chat(
                messages: messages,
                model: model,
                tools: AgentCoordinator.coreTools,
                maxTokens: 2048
            )

            guard let choice = response.choices.first else { break }
            let message = choice.message

            // If model returned text with no tool calls → done
            if let toolCalls = message.toolCalls, !toolCalls.isEmpty {
                // Add assistant's tool-calling message
                messages.append(ChatMessage(role: "assistant", text: message.content ?? ""))

                // Execute all tool calls
                for toolCall in toolCalls {
                    onStatusUpdate?("Using \(toolCall.function.name)…")
                    let result = await executeTool(name: toolCall.function.name,
                                                    arguments: toolCall.function.arguments)
                    // Append tool result
                    messages.append(ChatMessage(role: "tool", text: result))
                }

                // Update token count
                if let usage = response.usage {
                    print("[Agent] Tokens: \(usage.promptTokens) in, \(usage.completionTokens) out (step \(iterationCount))")
                }
            } else {
                // Final answer
                finalResponse = message.content ?? ""
                break
            }
        }

        // Save assistant response
        let assistantMsg = ConversationMessage.new(sessionId: sessionId, role: "assistant",
                                                    content: finalResponse, model: Config.brainModel)
        try? await database.pool.write { db in try assistantMsg.insert(db) }

        // Extract knowledge from the conversation
        Task { try? await knowledgeGraph.extractAndStore(text: query + "\n" + finalResponse, source: "conversation") }

        onStatusUpdate?("Done")
        return finalResponse
    }

    // MARK: - Tool Executor

    private func executeTool(name: String, arguments: String) async -> String {
        struct Args: Decodable {
            let command: String?
            let path: String?
            let content: String?
            let query: String?
            let title: String?
            let description: String?
            let priority: String?
            let task_title: String?
            let task_description: String?
        }

        let args = (try? JSONDecoder().decode(Args.self, from: Data(arguments.utf8))) ?? Args(
            command: nil, path: nil, content: nil, query: nil,
            title: nil, description: nil, priority: nil,
            task_title: nil, task_description: nil
        )

        switch name {

        case "shell":
            guard let command = args.command else { return "Error: no command provided" }
            return await runShell(command)

        case "read_file":
            guard let path = args.path else { return "Error: no path provided" }
            let expanded = (path as NSString).expandingTildeInPath
            do {
                let content = try String(contentsOfFile: expanded, encoding: .utf8)
                return String(content.prefix(8000)) // cap at 8k chars
            } catch {
                return "Error reading file: \(error.localizedDescription)"
            }

        case "write_file":
            guard let path = args.path, let content = args.content else {
                return "Error: path and content required"
            }
            let expanded = (path as NSString).expandingTildeInPath
            do {
                try content.write(toFile: expanded, atomically: true, encoding: .utf8)
                return "✅ Written to \(expanded)"
            } catch {
                return "Error writing file: \(error.localizedDescription)"
            }

        case "search_knowledge_graph":
            guard let query = args.query else { return "Error: no query" }
            do {
                let context = try await knowledgeGraph.buildContext(topic: query)
                return context
            } catch {
                return "KG search error: \(error.localizedDescription)"
            }

        case "create_task":
            guard let title = args.title else { return "Error: no title" }
            let task = ShiroTask.new(
                title: title,
                description: args.description,
                source: "sub_agent",
                priority: args.priority ?? "medium"
            )
            do {
                try await database.pool.write { db in try task.insert(db) }
                return "✅ Task created: \(title)"
            } catch {
                return "Error creating task: \(error.localizedDescription)"
            }

        case "web_search":
            guard let query = args.query else { return "Error: no query" }
            return await webSearch(query)

        case "get_screen_context":
            do {
                let recent = try await database.pool.read { db in
                    try Observation
                        .filter(Column("type") == "screen")
                        .order(Column("created_at").desc)
                        .limit(1)
                        .fetchOne(db)
                }
                return recent?.dataJSON ?? "No recent screen observations"
            } catch {
                return "Error: \(error.localizedDescription)"
            }

        case "spawn_sub_agent":
            guard let title = args.task_title, let desc = args.task_description else {
                return "Error: task_title and task_description required"
            }
            return await spawnSubAgent(title: title, description: desc)

        default:
            return "Unknown tool: \(name)"
        }
    }

    // MARK: - Tool Implementations

    private func runShell(_ command: String) async -> String {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-c", command]

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            process.terminationHandler = { _ in
                let out = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let result = [out, err].filter { !$0.isEmpty }.joined(separator: "\n")
                continuation.resume(returning: result.isEmpty ? "(no output)" : String(result.prefix(4000)))
            }

            do {
                try process.run()
            } catch {
                continuation.resume(returning: "Shell error: \(error.localizedDescription)")
            }
        }
    }

    private func webSearch(_ query: String) async -> String {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let urlStr = "https://api.duckduckgo.com/?q=\(encoded)&format=json&no_html=1&skip_disambig=1"
        guard let url = URL(string: urlStr) else { return "Invalid search URL" }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            struct DDGResponse: Decodable {
                let AbstractText: String?
                let RelatedTopics: [Topic]?
                struct Topic: Decodable { let Text: String? }
            }
            let resp = try JSONDecoder().decode(DDGResponse.self, from: data)
            var results: [String] = []
            if let abstract = resp.AbstractText, !abstract.isEmpty { results.append(abstract) }
            let topics = resp.RelatedTopics?.prefix(5).compactMap(\.Text) ?? []
            results.append(contentsOf: topics)
            return results.isEmpty ? "No results found" : results.joined(separator: "\n\n")
        } catch {
            return "Search error: \(error.localizedDescription)"
        }
    }

    private func spawnSubAgent(title: String, description: String) async -> String {
        // Create task, run it immediately as a sub-agent
        var task = ShiroTask.new(title: title, description: description, source: "sub_agent")
        task.status = "in_progress"
        task.assignedAgent = "sub_\(UUID().uuidString.prefix(4))"
        task.startedAt = Date()

        try? await database.pool.write { db in try task.insert(db) }

        do {
            // Sub-agent runs with same coordinator but separate session
            let result = try await run(query: description, sessionId: "sub_\(task.id)")

            // Mark task done
            var completed = task
            completed.status = "done"
            completed.result = result
            completed.completedAt = Date()
            try? await database.pool.write { db in try completed.update(db) }

            return "Sub-agent completed '\(title)':\n\(result.prefix(1000))"
        } catch {
            var failed = task
            failed.status = "cancelled"
            try? await database.pool.write { db in try failed.update(db) }
            return "Sub-agent failed for '\(title)': \(error.localizedDescription)"
        }
    }
}
