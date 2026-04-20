import Foundation

/// Routes Shiro agent queries through the local `claude` CLI in headless
/// stream-json mode, using the user's Claude Pro/Max subscription quota.
///
/// Contract with `claude -p --input-format stream-json --output-format stream-json --include-partial-messages`:
///   • stdin: newline-delimited JSON. Each turn is one `{"type":"user", ...}` line.
///   • stdout: newline-delimited JSON events (system/assistant/user/result/stream_event/error).
///
/// We map those to Shiro's existing `BridgeEvent` stream so AgentCoordinator and the
/// UI behave identically regardless of route.
///
/// Notes:
///   • The CLI runs its own built-in tools (Read/Write/Bash/Glob/Grep/WebFetch/…) using
///     its own permission model — we surface tool_use/tool_result events for display
///     but do NOT intercept execution (that would need Shiro's tools exposed as an MCP
///     server, a future upgrade).
///   • Filesystem access is controlled by `--add-dir` (see Config.allowedDirectories).
///   • Auth comes from the user's existing `claude` login in ~/.claude — nothing extra.
@MainActor
final class ClaudeCodeRouter: BridgeRouter {

    // MARK: - BridgeRouter surface

    var onEvent: ((BridgeEvent) -> Void)?
    private(set) var isRunning: Bool = false
    var routeLabel: String { "Claude Code CLI (subscription)" }

    // MARK: - Internals

    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var stdoutBuffer = Data()

    private var currentSessionId: String = ""
    private var streamingText: [String: String] = [:]   // sessionKey → accumulated text

    // Turn timeout tasks — keyed by sessionKey; cancelled on result/error.
    private var activeTurnTasks: [String: Task<Void, Never>] = [:]
    // Buffered query waiting for the bridge to come up.
    private var pendingQuery: (prompt: String, sessionKey: String, systemPrompt: String?,
                               cwd: String?, mode: String, model: String?, resume: String?)? = nil

    // MARK: - Launch

    func launch() throws {
        guard !isRunning else { return }
        guard let cli = Config.claudeCodeCLIPath else {
            throw ClaudeCodeError.cliNotInstalled
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: cli)

        var args: [String] = [
            "-p",
            "--input-format",  "stream-json",
            "--output-format", "stream-json",
            "--include-partial-messages",
            "--verbose",                                   // required for stream-json
            "--permission-mode", Config.claudePermissionMode,
        ]
        for dir in Config.allowedDirectories {
            args.append(contentsOf: ["--add-dir", dir])
        }
        // Pipe an empty prompt — stdin will carry the real user messages.
        // `claude -p` still requires a prompt arg unless stdin is a TTY; we pass " ".
        proc.arguments = args

        // Inherit the user's env so the existing `claude` login in ~/.claude is
        // picked up. Strip anything that would force API-key mode.
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "ANTHROPIC_API_KEY")     // use subscription, not API key
        env.removeValue(forKey: "ANTHROPIC_BASE_URL")
        proc.environment = env

        let stdin = Pipe(); let stdout = Pipe(); let stderr = Pipe()
        proc.standardInput  = stdin
        proc.standardOutput = stdout
        proc.standardError  = stderr
        self.stdinPipe  = stdin
        self.stdoutPipe = stdout
        self.stderrPipe = stderr

        stdout.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor [weak self] in self?.appendStdout(data) }
        }
        stderr.fileHandleForReading.readabilityHandler = { h in
            if let line = String(data: h.availableData, encoding: .utf8)?
                .trimmingCharacters(in: .newlines), !line.isEmpty {
                print("[claude stderr] \(line)")
            }
        }
        proc.terminationHandler = { [weak self] p in
            Task { @MainActor [weak self] in
                self?.isRunning = false
                self?.onEvent?(.bridgeError(
                    sessionKey: nil,
                    message: "claude CLI exited (code \(p.terminationStatus))"
                ))
            }
        }

        try proc.run()
        self.process   = proc
        self.isRunning = true
        print("[ClaudeCodeRouter] launched PID \(proc.processIdentifier) → \(cli)")
        print("[ClaudeCodeRouter] allowed dirs: \(Config.allowedDirectories.joined(separator: ", "))")
    }

    func stop() {
        process?.terminate()
        process = nil
        stdinPipe = nil
        stdoutPipe = nil
        stderrPipe = nil
        isRunning = false
    }

    // MARK: - Query

    func query(_ prompt: String,
               sessionKey: String = "main",
               systemPrompt: String? = nil,
               cwd: String? = nil,
               mode: String = "act",
               model: String? = nil,
               resume: String? = nil) {
        guard let handle = stdinPipe?.fileHandleForWriting, isRunning else {
            // Buffer and retry after 3 seconds.
            pendingQuery = (prompt: prompt, sessionKey: sessionKey, systemPrompt: systemPrompt,
                            cwd: cwd, mode: mode, model: model, resume: resume)
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard let self = self else { return }
                if self.isRunning, let pq = self.pendingQuery {
                    self.pendingQuery = nil
                    self.query(pq.prompt, sessionKey: pq.sessionKey, systemPrompt: pq.systemPrompt,
                               cwd: pq.cwd, mode: pq.mode, model: pq.model, resume: pq.resume)
                } else if let pq = self.pendingQuery {
                    self.pendingQuery = nil
                    self.onEvent?(.bridgeError(sessionKey: pq.sessionKey,
                                               message: "claude CLI not running after retry"))
                }
            }
            return
        }
        streamingText[sessionKey] = ""

        // Start 90-second turn timeout.
        activeTurnTasks[sessionKey]?.cancel()
        let sk = sessionKey
        activeTurnTasks[sk] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 90_000_000_000)
            guard let self = self, !Task.isCancelled else { return }
            self.activeTurnTasks.removeValue(forKey: sk)
            self.onEvent?(.bridgeError(sessionKey: sk, message: "turn timeout after 90s"))
        }

        // stream-json input line:
        //   {"type":"user","message":{"role":"user","content":"<prompt>"}}
        // If the caller provided a systemPrompt, prepend it inline (the CLI does
        // not accept per-message system prompts in stream-json mode; use
        // --append-system-prompt on launch for a persistent system prompt).
        let fullPrompt: String
        if let sp = systemPrompt, !sp.isEmpty {
            fullPrompt = "[System context: \(sp)]\n\n\(prompt)"
        } else {
            fullPrompt = prompt
        }
        let payload: [String: Any] = [
            "type": "user",
            "message": [
                "role": "user",
                "content": fullPrompt
            ]
        ]

        do {
            var data = try JSONSerialization.data(withJSONObject: payload)
            data.append(0x0A)
            try handle.write(contentsOf: data)
        } catch {
            onEvent?(.bridgeError(
                sessionKey: sessionKey,
                message: "claude stdin write failed: \(error.localizedDescription)"
            ))
        }
    }

    func interrupt(sessionKey: String?) {
        // The CLI respects SIGINT for graceful cancel of the current turn.
        guard let p = process, p.isRunning else { return }
        kill(p.processIdentifier, SIGINT)
    }

    func resolveApproval(callId: String, approved: Bool, denialReason: String?) {
        // No-op: the CLI handles its own permissions (--permission-mode).
        // Shiro-side ConsentGate still runs for tools the Swift layer exposes
        // separately (not available in CLI route today).
    }

    // MARK: - Stream parsing

    private func appendStdout(_ data: Data) {
        stdoutBuffer.append(data)
        while let nl = stdoutBuffer.firstRange(of: Data([0x0A])) {
            let line = Data(stdoutBuffer[stdoutBuffer.startIndex..<nl.lowerBound])
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex..<nl.upperBound)
            if line.isEmpty { continue }
            handle(line)
        }
    }

    private func handle(_ data: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else {
            let raw = String(data: data, encoding: .utf8) ?? "(non-utf8)"
            print("[ClaudeCodeRouter] unparseable: \(raw.prefix(200))")
            return
        }
        let sk = (obj["session_key"] as? String) ?? "main"

        switch type {

        case "system":
            // system.init contains session_id, tools, model — emit sessionReady.
            if (obj["subtype"] as? String) == "init" {
                let sid = (obj["session_id"] as? String) ?? ""
                currentSessionId = sid
                onEvent?(.sessionReady(sessionKey: sk, sessionId: sid))
            }

        case "stream_event":
            // Partial message deltas (with --include-partial-messages).
            if let ev = obj["event"] as? [String: Any],
               (ev["type"] as? String) == "content_block_delta",
               let delta = ev["delta"] as? [String: Any] {
                switch delta["type"] as? String {
                case "text_delta":
                    if let t = delta["text"] as? String {
                        streamingText[sk, default: ""] += t
                        onEvent?(.textDelta(sessionKey: sk, text: t))
                    }
                case "thinking_delta":
                    if let t = delta["thinking"] as? String {
                        onEvent?(.thinkingDelta(sessionKey: sk, text: t))
                    }
                default:
                    break
                }
            }

        case "assistant":
            // Full assistant message — surface tool_use blocks for UI spinners,
            // and emit any text not already streamed via stream_event so short
            // non-streamed replies still reach the UI.
            if let msg = obj["message"] as? [String: Any],
               let content = msg["content"] as? [[String: Any]] {
                for block in content {
                    switch block["type"] as? String {
                    case "tool_use":
                        let callId = (block["id"]    as? String) ?? UUID().uuidString
                        let name   = (block["name"]  as? String) ?? "unknown"
                        let input  = (block["input"] as? [String: Any]) ?? [:]
                        onEvent?(.toolStarted(sessionKey: sk, callId: callId,
                                              name: name, input: input))
                    case "text":
                        if let t = block["text"] as? String {
                            let already = streamingText[sk, default: ""]
                            // Only emit the tail we haven't streamed yet.
                            if t.count > already.count, t.hasPrefix(already) {
                                let tail = String(t.dropFirst(already.count))
                                streamingText[sk] = t
                                if !tail.isEmpty {
                                    onEvent?(.textDelta(sessionKey: sk, text: tail))
                                }
                            } else if already.isEmpty {
                                streamingText[sk] = t
                                onEvent?(.textDelta(sessionKey: sk, text: t))
                            }
                        }
                    default:
                        break
                    }
                }
            }

        case "user":
            // Tool-result events echoed back from the CLI.
            if let msg = obj["message"] as? [String: Any],
               let content = msg["content"] as? [[String: Any]] {
                for block in content where (block["type"] as? String) == "tool_result" {
                    let callId = (block["tool_use_id"] as? String) ?? ""
                    let output = Self.extractToolResultText(block)
                    let isErr  = (block["is_error"] as? Bool) ?? false
                    onEvent?(.toolFinished(sessionKey: sk, callId: callId,
                                           output: output, isError: isErr))
                }
            }

        case "result":
            // Cancel the turn timeout.
            activeTurnTasks.removeValue(forKey: sk)?.cancel()
            let finalText = (obj["result"] as? String)
                ?? streamingText[sk]
                ?? ""
            let usage  = obj["usage"] as? [String: Any] ?? [:]
            let inTok  = (usage["input_tokens"]  as? Int) ?? 0
            let outTok = (usage["output_tokens"] as? Int) ?? 0
            // Subscription-backed calls report $0 cost — that's expected and correct.
            let cost   = (obj["total_cost_usd"]  as? Double) ?? 0
            streamingText[sk] = ""
            onEvent?(.turnComplete(
                sessionKey: sk, text: finalText,
                inputTokens: inTok, outputTokens: outTok, costUsd: cost
            ))

        case "error":
            // Cancel the turn timeout.
            activeTurnTasks.removeValue(forKey: sk)?.cancel()
            let msg = (obj["message"] as? String) ?? "unknown error"
            onEvent?(.bridgeError(sessionKey: sk, message: msg))

        default:
            // Silently ignore well-known informational event types that carry no message.
            if let msg = obj["message"] as? String {
                onEvent?(.bridgeLog(level: "info", message: "\(type): \(msg)"))
            }
            // If no "message" key — just return silently (e.g. rate_limit_event, hook events).
        }
    }

    private static func extractToolResultText(_ block: [String: Any]) -> String {
        if let s = block["content"] as? String { return s }
        if let arr = block["content"] as? [[String: Any]] {
            return arr.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        return "(tool result)"
    }

    // MARK: - Errors

    enum ClaudeCodeError: LocalizedError {
        case cliNotInstalled
        var errorDescription: String? {
            switch self {
            case .cliNotInstalled:
                return """
                Claude CLI not found. Install with one of:
                  • curl -fsSL https://claude.ai/install.sh | bash
                  • npm install -g @anthropic-ai/claude-code
                Then run `claude` once and complete browser login.
                """
            }
        }
    }
}
