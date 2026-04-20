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

// MARK: - AgentCoordinator

/// Central agent facade. Routes queries through ACPBridge (Node + Claude SDK)
/// when available; falls back to the legacy LM Studio ReACT loop otherwise.
@MainActor
final class AgentCoordinator: ObservableObject {

    private let database: ShiroDatabase
    private let lmStudio: LMStudioClient
    private let knowledgeGraph: KnowledgeGraphService

    /// Set by AppState once all services are ready.
    /// Can be any BridgeRouter implementation (ACPBridge or ClaudeCodeRouter).
    var bridge: (any BridgeRouter)?

    @Published var isRunning: Bool = false
    @Published var currentTaskTitle: String = ""
    @Published var iterationCount: Int = 0
    @Published var streamingText: String = ""
    @Published var pendingApprovals: [ApprovalRequest] = []

    // 120-second safety timeout task — cancelled on turn completion or error.
    private var safetyTimeoutTask: Task<Void, Never>? = nil

    var onStatusUpdate: ((String) -> Void)?
    var onStreamingToken: ((String) -> Void)?
    var onTurnComplete: ((String) -> Void)?

    struct ApprovalRequest: Identifiable {
        let id: String           // callId
        let sessionKey: String
        let toolName: String
        let input: [String: Any]
        let justification: String?
        let risk: ToolRisk
    }

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
        self.database       = database
        self.lmStudio       = lmStudio
        self.knowledgeGraph = knowledgeGraph
    }

    // MARK: - Bridge wiring

    /// Connect a running bridge router and subscribe to its events.
    func connectBridge(_ b: any BridgeRouter) {
        self.bridge = b
        b.onEvent = { [weak self] event in
            self?.handleBridgeEvent(event)
        }
    }

    private func handleBridgeEvent(_ event: BridgeEvent) {
        // Push tool events to the UI feed (AppState) — updates Tool Feed panel + inline chips.
        Task { @MainActor in AppState.shared.handleBridgeEventForUI(event) }

        switch event {

        case .sessionReady(_, _):
            onStatusUpdate?("Connected")

        case .textDelta(_, let text):
            streamingText += text
            onStreamingToken?(text)

        case .thinkingDelta:
            break  // suppress from main chat for now

        case .toolStarted(_, _, let name, _):
            isRunning = true
            onStatusUpdate?("Using \(name)…")
            Task { @MainActor in AppState.shared.agentStatus = .acting(tool: name) }

        case .toolFinished:
            break

        case .turnComplete(_, let text, let inTok, let outTok, let cost):
            safetyTimeoutTask?.cancel()
            safetyTimeoutTask = nil
            isRunning  = false
            streamingText = ""
            onStatusUpdate?("Done  (\(inTok)→\(outTok) tok, $\(String(format: "%.4f", cost)))")
            onTurnComplete?(text)

        case .agentSpawned(_, let taskId):
            onStatusUpdate?("Sub-agent spawned: \(taskId)")

        case .agentDone(_, let taskId, let status, _):
            onStatusUpdate?("Sub-agent \(taskId) \(status)")

        case .approvalRequired(let callId, let sk, let name, let input, let just, let risk):
            let req = ApprovalRequest(id: callId, sessionKey: sk, toolName: name,
                                       input: input, justification: just, risk: risk)
            pendingApprovals.append(req)

        case .bridgeError(_, let msg):
            safetyTimeoutTask?.cancel()
            safetyTimeoutTask = nil
            isRunning = false
            AppState.shared.isProcessing = false
            onStatusUpdate?("Error: \(msg)")

        case .bridgeLog(let level, let msg):
            if level == "error" { print("[bridge error] \(msg)") }
        }
    }

    // MARK: - Primary entry point

    /// Preferred path: send through ACPBridge (Node + Claude SDK).
    /// Falls back to legacy ReACT loop if bridge isn't running.
    func send(query prompt: String, sessionKey: String = "main",
              systemPrompt: String? = nil, mode: String = "act") async throws -> String {
        if let b = bridge, b.isRunning {
            // Reset streaming buffer.
            streamingText = ""
            isRunning     = true
            currentTaskTitle = String(prompt.prefix(60))
            b.query(prompt, sessionKey: sessionKey, systemPrompt: systemPrompt,
                    cwd: nil, mode: mode, model: nil, resume: nil)

            // 120-second safety timeout in case turnComplete never fires.
            safetyTimeoutTask?.cancel()
            safetyTimeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 120_000_000_000)
                guard let self = self, !Task.isCancelled else { return }
                if self.isRunning {
                    self.isRunning = false
                    AppState.shared.isProcessing = false
                }
            }

            // Result arrives asynchronously via handleBridgeEvent(.turnComplete).
            // Callers who need the final text should observe `onTurnComplete`.
            return ""
        } else {
            // Legacy fallback.
            return try await run(query: prompt)
        }
    }

    // MARK: - Legacy ReACT Loop

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
            let response: ChatCompletionResponse
            do {
                response = try await lmStudio.chat(
                    messages: messages,
                    model: model,
                    tools: AgentCoordinator.coreTools,
                    maxTokens: 2048
                )
            } catch {
                isRunning = false
                throw error
            }

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
        // Run off the main actor so Process fork/exec doesn't stall the UI.
        await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                process.arguments = ["-c", command]

                let stdout = Pipe()
                let stderr = Pipe()
                process.standardOutput = stdout
                process.standardError = stderr

                // Guard against double-resume if run() throws after
                // terminationHandler also fires (rare but defensive).
                let resumeLock = NSLock()
                var didResume  = false
                func resumeOnce(_ s: String) {
                    resumeLock.lock(); defer { resumeLock.unlock() }
                    guard !didResume else { return }
                    didResume = true
                    continuation.resume(returning: s)
                }

                process.terminationHandler = { _ in
                    let out = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    let result = [out, err].filter { !$0.isEmpty }.joined(separator: "\n")
                    resumeOnce(result.isEmpty ? "(no output)" : String(result.prefix(4000)))
                }

                do {
                    try process.run()
                } catch {
                    resumeOnce("Shell error: \(error.localizedDescription)")
                }
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
                let abstractText: String?
                let relatedTopics: [Topic]?

                enum CodingKeys: String, CodingKey {
                    case abstractText  = "AbstractText"
                    case relatedTopics = "RelatedTopics"
                }

                struct Topic: Decodable {
                    let text: String?
                    enum CodingKeys: String, CodingKey { case text = "Text" }
                }
            }
            let resp = try JSONDecoder().decode(DDGResponse.self, from: data)
            var results: [String] = []
            if let abstract = resp.abstractText, !abstract.isEmpty { results.append(abstract) }
            let topics = resp.relatedTopics?.prefix(5).compactMap(\.text) ?? []
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

        // Snapshot before crossing a Sendable closure boundary.
        let taskSnap = task
        try? await database.pool.write { db in try taskSnap.insert(db) }

        do {
            // Sub-agent runs with same coordinator but separate session
            let result = try await run(query: description, sessionId: "sub_\(taskSnap.id)")

            // Mark task done — build the completed record as a `let` snapshot.
            var completed = taskSnap
            completed.status      = "done"
            completed.result      = result
            completed.completedAt = Date()
            let doneSnap = completed
            try? await database.pool.write { db in try doneSnap.update(db) }

            return "Sub-agent completed '\(title)':\n\(result.prefix(1000))"
        } catch {
            var failed = taskSnap
            failed.status = "cancelled"
            let failSnap = failed
            try? await database.pool.write { db in try failSnap.update(db) }
            return "Sub-agent failed for '\(title)': \(error.localizedDescription)"
        }
    }
}
