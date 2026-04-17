import Foundation
import GRDB

// MARK: - Bridge Protocol Types

/// All possible messages we send to the Node bridge (stdin).
enum BridgeInbound: Encodable {

    case query(id: String, prompt: String, systemPrompt: String?,
               sessionKey: String, cwd: String?, mode: String, model: String?)
    case toolResult(callId: String, result: String, isError: Bool, denied: Bool, denialReason: String?)
    case interrupt(sessionKey: String?)
    case warmup(sessionKeys: [String], cwd: String?)
    case resetSession(sessionKey: String?)
    case spawnAgent(sessionKey: String, parentKey: String?,
                    taskId: String, persona: String, prompt: String,
                    model: String?, costBudgetUsd: Double?, depthBudget: Int?, cwd: String?)
    case stop

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .query(id, prompt, system, session, cwd, mode, model):
            try c.encode("query",      forKey: .type)
            try c.encode(id,           forKey: .id)
            try c.encode(prompt,       forKey: .prompt)
            try c.encodeIfPresent(system,  forKey: .systemPrompt)
            try c.encode(session,      forKey: .sessionKey)
            try c.encodeIfPresent(cwd, forKey: .cwd)
            try c.encode(mode,         forKey: .mode)
            try c.encodeIfPresent(model, forKey: .model)

        case let .toolResult(callId, result, isError, denied, denialReason):
            try c.encode("tool_result", forKey: .type)
            try c.encode(callId,        forKey: .callId)
            try c.encode(result,        forKey: .result)
            if isError  { try c.encode(isError,      forKey: .isError) }
            if denied   { try c.encode(denied,        forKey: .denied)  }
            try c.encodeIfPresent(denialReason, forKey: .denialReason)

        case let .interrupt(key):
            try c.encode("interrupt", forKey: .type)
            try c.encodeIfPresent(key, forKey: .sessionKey)

        case let .warmup(keys, cwd):
            try c.encode("warmup", forKey: .type)
            let sessions = keys.map { ["key": $0] }
            try c.encode(sessions, forKey: .sessions)
            try c.encodeIfPresent(cwd, forKey: .cwd)

        case let .resetSession(key):
            try c.encode("resetSession", forKey: .type)
            try c.encodeIfPresent(key, forKey: .sessionKey)

        case let .spawnAgent(sk, pk, tid, persona, prompt, model, cost, depth, cwd):
            try c.encode("spawn_agent",  forKey: .type)
            try c.encode(sk,             forKey: .sessionKey)
            try c.encodeIfPresent(pk,    forKey: .parentSessionKey)
            try c.encode(tid,            forKey: .taskId)
            try c.encode(persona,        forKey: .persona)
            try c.encode(prompt,         forKey: .prompt)
            try c.encodeIfPresent(model, forKey: .model)
            try c.encodeIfPresent(cost,  forKey: .costBudgetUsd)
            try c.encodeIfPresent(depth, forKey: .depthBudget)
            try c.encodeIfPresent(cwd,   forKey: .cwd)

        case .stop:
            try c.encode("stop", forKey: .type)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type, id, prompt, systemPrompt, sessionKey, parentSessionKey
        case cwd, mode, model, callId, result, isError, denied, denialReason
        case sessions, taskId, persona, costBudgetUsd, depthBudget
    }
}

/// All possible messages we receive from the Node bridge (stdout).
struct BridgeOutbound: Decodable {
    let type: String
    // init / text / thinking / tool_use / tool_activity / tool_result_display / result / error
    // agent_started / agent_finished / log
    let sessionId:  String?
    let sessionKey: String?

    // text_delta / thinking_delta / text_block_boundary
    let text: String?

    // tool_use
    let callId:        String?
    let name:          String?
    let input:         AnyCodable?
    let riskLevel:     String?
    let justification: String?

    // tool_activity
    let status: String?

    // result
    let inputTokens:  Int?
    let outputTokens: Int?
    let costUsd:      Double?

    // error
    let message: String?

    // agent_started / agent_finished
    let taskId:   String?
    let persona:  String?
    let summary:  String?

    // tool_result_display
    let toolUseId: String?
    let output:    String?
    let isError:   Bool?

    // log
    let level: String?
}

// Opaque JSON wrapper so `input` decodes without knowing its shape.
struct AnyCodable: Decodable {
    let value: Any

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let d = try? c.decode([String: AnyCodableLeaf].self) { value = d.mapValues(\.value); return }
        if let a = try? c.decode([AnyCodableLeaf].self) { value = a.map(\.value); return }
        value = [:]
    }

    var dictionary: [String: Any] { (value as? [String: Any]) ?? [:] }
}

struct AnyCodableLeaf: Decodable {
    let value: Any
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self)  { value = s; return }
        if let i = try? c.decode(Int.self)     { value = i; return }
        if let d = try? c.decode(Double.self)  { value = d; return }
        if let b = try? c.decode(Bool.self)    { value = b; return }
        value = ""
    }
}

// MARK: - Consent Gate

enum ToolRisk: String {
    case low, med, high

    /// Consent Gate policy:
    /// low  → auto-approve silently
    /// med  → toast with 3-second veto window (not yet implemented — auto-approve for MVP)
    /// high → blocking ApprovalCard
    var requiresExplicitApproval: Bool { self == .high }
}

// MARK: - ACPBridge Events (published to AgentCoordinator / UI)

enum BridgeEvent {
    case sessionReady(sessionKey: String, sessionId: String)
    case textDelta(sessionKey: String, text: String)
    case thinkingDelta(sessionKey: String, text: String)
    case toolStarted(sessionKey: String, callId: String, name: String, input: [String: Any])
    case toolFinished(sessionKey: String, callId: String, output: String, isError: Bool)
    case turnComplete(sessionKey: String, text: String, inputTokens: Int, outputTokens: Int, costUsd: Double)
    case agentSpawned(sessionKey: String, taskId: String)
    case agentDone(sessionKey: String, taskId: String, status: String, summary: String)
    case bridgeError(sessionKey: String?, message: String)
    case bridgeLog(level: String, message: String)
    /// Emitted when a high-risk tool needs user approval before Swift executes it.
    /// The handler must call `ACPBridge.resolveApproval(callId:approved:)` to continue.
    case approvalRequired(callId: String, sessionKey: String, name: String,
                          input: [String: Any], justification: String?, risk: ToolRisk)
}

// MARK: - ACPBridge

/// Manages the lifecycle of the Node acp-bridge subprocess.
/// Thread model: all public methods are called from @MainActor.
/// Internal I/O callbacks are dispatched back to MainActor before firing.
@MainActor
final class ACPBridge {

    // MARK: - Public interface

    var onEvent: ((BridgeEvent) -> Void)?

    private(set) var isRunning: Bool = false
    private(set) var bridgePID: Int32 = 0

    // MARK: - Internals

    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var stdoutBuffer = Data()

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    // Pending approval gates — keyed by callId.
    // We stash the (name, input) so we can execute after approval.
    private struct PendingApproval {
        let callId: String
        let sessionKey: String
        let name: String
        let input: [String: Any]
        let justification: String?
        let risk: ToolRisk
    }
    private var pendingApprovals: [String: PendingApproval] = [:]

    // Back-references to services for tool execution.
    private weak var database: ShiroDatabase?
    private weak var knowledgeGraph: KnowledgeGraphService?
    private weak var lmStudio: LMStudioClient?
    private weak var screenCapture: ScreenCaptureService?

    // MARK: - Init

    init(database: ShiroDatabase,
         knowledgeGraph: KnowledgeGraphService,
         lmStudio: LMStudioClient,
         screenCapture: ScreenCaptureService) {
        self.database      = database
        self.knowledgeGraph = knowledgeGraph
        self.lmStudio      = lmStudio
        self.screenCapture = screenCapture
    }

    // MARK: - Launch

    func launch() throws {
        guard !isRunning else { return }

        let nodePath  = nodeExecutablePath()
        let indexPath = bridgeIndexPath()

        guard FileManager.default.fileExists(atPath: indexPath) else {
            throw ACPBridgeError.bridgeNotBuilt(indexPath)
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: nodePath)
        proc.arguments     = [indexPath]
        proc.environment   = buildEnvironment()

        let stdin  = Pipe(); let stdout = Pipe(); let stderr = Pipe()
        proc.standardInput  = stdin
        proc.standardOutput = stdout
        proc.standardError  = stderr
        self.stdinPipe  = stdin
        self.stdoutPipe = stdout
        self.stderrPipe = stderr

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor [weak self] in
                self?.appendStdout(data)
            }
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            if let line = String(data: handle.availableData, encoding: .utf8)?.trimmingCharacters(in: .newlines), !line.isEmpty {
                print("[bridge stderr] \(line)")
            }
        }
        proc.terminationHandler = { [weak self] p in
            Task { @MainActor [weak self] in
                self?.isRunning = false
                self?.onEvent?(.bridgeError(sessionKey: nil, message: "Bridge exited (code \(p.terminationStatus))"))
            }
        }

        try proc.run()
        self.process  = proc
        self.bridgePID = proc.processIdentifier
        self.isRunning = true
        print("[ACPBridge] launched PID \(bridgePID) → \(indexPath)")
    }

    func stop() {
        send(.stop)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.process?.terminate()
        }
    }

    // MARK: - Send query

    func query(_ prompt: String,
               sessionKey: String = "main",
               systemPrompt: String? = nil,
               cwd: String? = nil,
               mode: String = "act",
               model: String? = nil,
               resume: String? = nil) {
        let msg = BridgeInbound.query(
            id:           UUID().uuidString,
            prompt:       prompt,
            systemPrompt: systemPrompt,
            sessionKey:   sessionKey,
            cwd:          cwd ?? FileManager.default.currentDirectoryPath,
            mode:         mode,
            model:        model
        )
        send(msg)
    }

    func interrupt(sessionKey: String? = nil) {
        send(.interrupt(sessionKey: sessionKey))
    }

    // MARK: - Approval resolution

    /// Called by UI (ApprovalCardView or TelegramRelay) after user approves/denies.
    func resolveApproval(callId: String, approved: Bool, denialReason: String? = nil) {
        guard let pending = pendingApprovals[callId] else { return }
        pendingApprovals.removeValue(forKey: callId)

        if approved {
            Task { [weak self] in
                await self?.executeToolAndReply(
                    callId:     pending.callId,
                    sessionKey: pending.sessionKey,
                    name:       pending.name,
                    input:      pending.input
                )
            }
        } else {
            send(.toolResult(callId: callId, result: "", isError: false,
                             denied: true, denialReason: denialReason ?? "User denied"))
        }
    }

    // MARK: - Stdout parsing

    private func appendStdout(_ data: Data) {
        stdoutBuffer.append(data)
        while let nlRange = stdoutBuffer.firstRange(of: Data([0x0A])) {
            let lineData = stdoutBuffer[stdoutBuffer.startIndex..<nlRange.lowerBound]
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex...nlRange.lowerBound)
            if lineData.isEmpty { continue }
            do {
                let msg = try decoder.decode(BridgeOutbound.self, from: lineData)
                dispatchOutbound(msg)
            } catch {
                let raw = String(data: lineData, encoding: .utf8) ?? "(non-utf8)"
                print("[ACPBridge] decode error: \(error) — raw: \(raw.prefix(200))")
            }
        }
    }

    private func dispatchOutbound(_ msg: BridgeOutbound) {
        let sk = msg.sessionKey ?? "main"
        let sid = msg.sessionId ?? ""

        switch msg.type {

        case "init":
            onEvent?(.sessionReady(sessionKey: sk, sessionId: sid))

        case "text_delta":
            onEvent?(.textDelta(sessionKey: sk, text: msg.text ?? ""))

        case "thinking_delta":
            onEvent?(.thinkingDelta(sessionKey: sk, text: msg.text ?? ""))

        case "text_block_boundary":
            break  // UI uses this to know a paragraph ended; ignore for now.

        case "tool_use":
            guard let callId = msg.callId, let name = msg.name else { return }
            let input     = msg.input?.dictionary ?? [:]
            let riskRaw   = msg.riskLevel ?? "high"
            let risk      = ToolRisk(rawValue: riskRaw) ?? .high

            onEvent?(.toolStarted(sessionKey: sk, callId: callId, name: name, input: input))

            if risk.requiresExplicitApproval {
                // Stash and fire approvalRequired — UI must call resolveApproval().
                let approval = PendingApproval(callId: callId, sessionKey: sk, name: name,
                                               input: input, justification: msg.justification, risk: risk)
                pendingApprovals[callId] = approval
                onEvent?(.approvalRequired(callId: callId, sessionKey: sk, name: name,
                                           input: input, justification: msg.justification, risk: risk))
            } else {
                // Low/med — auto-execute.
                Task { [weak self] in
                    await self?.executeToolAndReply(callId: callId, sessionKey: sk, name: name, input: input)
                }
            }

        case "tool_activity", "tool_result_display":
            break  // UI uses these for spinners; bubbled via toolStarted/toolFinished.

        case "result":
            onEvent?(.turnComplete(
                sessionKey:   sk,
                text:         msg.text ?? "",
                inputTokens:  msg.inputTokens  ?? 0,
                outputTokens: msg.outputTokens ?? 0,
                costUsd:      msg.costUsd       ?? 0
            ))

        case "error":
            onEvent?(.bridgeError(sessionKey: sk, message: msg.message ?? "unknown error"))

        case "agent_started":
            if let taskId = msg.taskId {
                onEvent?(.agentSpawned(sessionKey: sk, taskId: taskId))
            }

        case "agent_finished":
            if let taskId = msg.taskId {
                onEvent?(.agentDone(sessionKey: sk, taskId: taskId,
                                    status: msg.status ?? "completed",
                                    summary: msg.summary ?? ""))
            }

        case "log":
            let level = msg.level ?? "info"
            onEvent?(.bridgeLog(level: level, message: msg.message ?? ""))

        default:
            break
        }
    }

    // MARK: - Tool Execution

    private func executeToolAndReply(
        callId:     String,
        sessionKey: String,
        name:       String,
        input:      [String: Any]
    ) async {
        let result = await executeTool(name: name, input: input)
        onEvent?(.toolFinished(sessionKey: sessionKey, callId: callId,
                               output: result.text, isError: result.isError))
        send(.toolResult(callId: callId, result: result.text,
                         isError: result.isError, denied: false, denialReason: nil))
    }

    private struct ToolResult {
        let text: String
        let isError: Bool
    }

    private func executeTool(name: String, input: [String: Any]) async -> ToolResult {
        func str(_ key: String) -> String? { input[key] as? String }
        func int(_ key: String) -> Int?    { input[key] as? Int }

        switch name {

        case "execute_sql":
            guard let query = str("query") else {
                return ToolResult(text: "Error: missing `query`", isError: true)
            }
            guard let db = database else {
                return ToolResult(text: "Error: database unavailable", isError: true)
            }
            return await executeSQLTool(query: query, db: db)

        case "capture_screenshot":
            guard let sc = screenCapture else {
                return ToolResult(text: "Error: screen capture unavailable", isError: true)
            }
            let mode = str("mode") ?? "screen"
            return await captureScreenshot(service: sc, mode: mode)

        case "query_kg":
            guard let kg = knowledgeGraph else {
                return ToolResult(text: "Error: knowledge graph unavailable", isError: true)
            }
            let query  = str("query") ?? ""
            let limit  = int("limit") ?? 25
            return await queryKG(service: kg, query: query, limit: limit)

        case "search_memory":
            // Phase 3 — RAG not yet wired. Return a helpful placeholder.
            return ToolResult(text: "Memory search not yet available (Phase 3). Use `query_kg` for now.", isError: false)

        case "file_read":
            guard let path = str("path") else {
                return ToolResult(text: "Error: missing `path`", isError: true)
            }
            return readFile(path: path, offset: int("offset"), limit: int("limit"))

        case "file_write":
            guard let path = str("path"), let content = str("content") else {
                return ToolResult(text: "Error: missing `path` or `content`", isError: true)
            }
            return writeFile(path: path, content: content)

        case "shell_exec":
            guard let command = str("command") else {
                return ToolResult(text: "Error: missing `command`", isError: true)
            }
            let cwd = str("cwd")
            return await runShell(command: command, cwd: cwd)

        case "macos_action":
            // Phase 2.5 — macOS Accessibility automation. Shim for now.
            return ToolResult(text: "macOS actions not yet available (Phase 2.5)", isError: false)

        case "spawn_subagent":
            guard let taskId = str("taskId"), let persona = str("persona"), let prompt = str("prompt") else {
                return ToolResult(text: "Error: missing taskId, persona, or prompt", isError: true)
            }
            let sessionKey = "agent:\(taskId)"
            send(.spawnAgent(
                sessionKey:    sessionKey,
                parentKey:     "main",
                taskId:        taskId,
                persona:       persona,
                prompt:        prompt,
                model:         str("model"),
                costBudgetUsd: input["costBudgetUsd"] as? Double,
                depthBudget:   int("depthBudget"),
                cwd:           nil
            ))
            return ToolResult(text: "Sub-agent spawned as session \"\(sessionKey)\"", isError: false)

        case "ask_followup":
            guard let question = str("question") else {
                return ToolResult(text: "Error: missing `question`", isError: true)
            }
            // For MVP, we synthesize a prompt to the user.
            // In Phase 5 when we have the floating bar question UI, this will be interactive.
            return ToolResult(text: "Question for user: \(question)\n(Awaiting UI integration — Phase 5)", isError: false)

        default:
            return ToolResult(text: "Unknown tool: \(name)", isError: true)
        }
    }

    // MARK: - Individual tool implementations

    private func executeSQLTool(query: String, db: ShiroDatabase) async -> ToolResult {
        do {
            let result = try await db.pool.read { dbConn -> String in
                let normalized = query.trimmingCharacters(in: .whitespaces).uppercased()
                guard normalized.hasPrefix("SELECT") || normalized.hasPrefix("WITH") ||
                      normalized.hasPrefix("INSERT") || normalized.hasPrefix("UPDATE") ||
                      normalized.hasPrefix("DELETE") else {
                    return "Error: only SELECT / WITH / INSERT / UPDATE / DELETE are permitted."
                }
                var rows: [[String: DatabaseValue]] = []
                let statement = try dbConn.makeStatement(sql: query)
                let cursor = try Row.fetchCursor(statement)
                var count = 0
                while let row = try cursor.next() {
                    guard count < 500 else { break }
                    rows.append(Dictionary(uniqueKeysWithValues:
                        row.columnNames.enumerated().map { (_, name) in (name, row[name] as DatabaseValue) }
                    ))
                    count += 1
                }
                if rows.isEmpty { return "(0 rows)" }
                let json = try JSONSerialization.data(withJSONObject: rows.map { row in
                    row.mapValues { val -> Any in
                        if case .blob(let d) = val.storage { return d.base64EncodedString() }
                        return val.description
                    }
                })
                return String(data: json, encoding: .utf8) ?? "(encoding error)"
            }
            return ToolResult(text: result, isError: false)
        } catch {
            return ToolResult(text: "SQL error: \(error.localizedDescription)", isError: true)
        }
    }

    private func captureScreenshot(service: ScreenCaptureService, mode: String) async -> ToolResult {
        // ScreenCaptureService returns base64 JPEG via existing path.
        // We call captureCurrentFrame() and encode it.
        do {
            let data = try await service.captureFrame()
            let b64  = data.base64EncodedString()
            return ToolResult(text: b64, isError: false)
        } catch {
            return ToolResult(text: "ERROR: \(error.localizedDescription)", isError: true)
        }
    }

    private func queryKG(service: KnowledgeGraphService, query: String, limit: Int) async -> ToolResult {
        do {
            let context = try await service.buildContext(topic: query)
            return ToolResult(text: context.isEmpty ? "(no results)" : context, isError: false)
        } catch {
            return ToolResult(text: "KG error: \(error.localizedDescription)", isError: true)
        }
    }

    private func readFile(path: String, offset: Int?, limit: Int?) -> ToolResult {
        let expanded = (path as NSString).expandingTildeInPath
        do {
            let raw   = try String(contentsOfFile: expanded, encoding: .utf8)
            let lines = raw.components(separatedBy: "\n")
            let from  = max(0, (offset ?? 1) - 1)
            let to    = min(lines.count, from + (limit ?? 2000))
            guard from < lines.count else {
                return ToolResult(text: "(offset beyond file end)", isError: false)
            }
            return ToolResult(text: lines[from..<to].joined(separator: "\n"), isError: false)
        } catch {
            return ToolResult(text: "Error reading \(expanded): \(error.localizedDescription)", isError: true)
        }
    }

    private func writeFile(path: String, content: String) -> ToolResult {
        let expanded = (path as NSString).expandingTildeInPath
        do {
            try content.write(toFile: expanded, atomically: true, encoding: .utf8)
            return ToolResult(text: "✅ Written to \(expanded)", isError: false)
        } catch {
            return ToolResult(text: "Error writing \(expanded): \(error.localizedDescription)", isError: true)
        }
    }

    private func runShell(command: String, cwd: String?) async -> ToolResult {
        await withCheckedContinuation { cont in
            let proc  = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
            proc.arguments     = ["-c", command]
            if let d = cwd { proc.currentDirectoryURL = URL(fileURLWithPath: d) }
            let stdout = Pipe(); let stderr = Pipe()
            proc.standardOutput = stdout; proc.standardError = stderr
            proc.terminationHandler = { _ in
                let out = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let combined = [out, err].filter { !$0.isEmpty }.joined(separator: "\n")
                cont.resume(returning: ToolResult(
                    text: combined.isEmpty ? "(no output)" : String(combined.prefix(8000)),
                    isError: proc.terminationStatus != 0
                ))
            }
            do    { try proc.run() }
            catch { cont.resume(returning: ToolResult(text: "Shell error: \(error)", isError: true)) }
        }
    }

    // MARK: - Helpers

    private func send(_ msg: BridgeInbound) {
        guard let handle = stdinPipe?.fileHandleForWriting else { return }
        do {
            var data = try encoder.encode(msg)
            data.append(0x0A) // newline
            try handle.write(contentsOf: data)
        } catch {
            print("[ACPBridge] send error: \(error)")
        }
    }

    private func nodeExecutablePath() -> String {
        ProcessInfo.processInfo.environment["SHIRO_NODE_PATH"]
            ?? "/Users/abhisheksharma/node-v20.12.2-darwin-arm64/bin/node"
    }

    private func bridgeIndexPath() -> String {
        // In development: relative to the repo root.
        // In release: we'll bundle dist/ inside the .app Resources.
        if let override = ProcessInfo.processInfo.environment["SHIRO_BRIDGE_PATH"] {
            return override
        }
        let repoRoot = Bundle.main.bundlePath
            .replacingOccurrences(of: "/DerivedData/.*", with: "", options: .regularExpression)
        // Fallback: look for the compiled bridge next to this binary.
        let dev = "/Users/abhisheksharma/Projects/shiro/acp-bridge/dist/index.js"
        return FileManager.default.fileExists(atPath: dev) ? dev : repoRoot + "/acp-bridge/dist/index.js"
    }

    private func buildEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        // Bridge discovers LM Studio URL from env.
        env["LM_STUDIO_URL"]      = Config.lmStudioBaseURL
        env["ANTHROPIC_API_KEY"]  = "lm-studio"
        // Don't pass ANTHROPIC_BASE_URL — bridge sets it once proxy boots.
        env.removeValue(forKey: "ANTHROPIC_BASE_URL")
        return env
    }
}

// MARK: - Errors

enum ACPBridgeError: LocalizedError {
    case bridgeNotBuilt(String)
    case bridgeAlreadyRunning

    var errorDescription: String? {
        switch self {
        case .bridgeNotBuilt(let path):
            return "acp-bridge not built. Run `npm run build` in acp-bridge/. Expected: \(path)"
        case .bridgeAlreadyRunning:
            return "ACPBridge is already running."
        }
    }
}
