import Foundation

// MARK: - ClaudeEvent

enum ClaudeEvent: Sendable {
    case assistantText(String)
    // [A1-fix] [String: Any] is non-Sendable. Send JSON string instead; callers decode if needed.
    case toolUse(name: String, inputJSON: String)
    case toolResult(name: String, output: String, isError: Bool)
    case usage(inputTokens: Int, outputTokens: Int, costUSD: Double)
    case sessionId(String)
    case done(RunResult)
    case error(String)

    struct RunResult: Sendable {
        let exitCode: Int32
        let totalCostUSD: Double
        let durationSeconds: TimeInterval
        let sessionId: String?
    }
}

// MARK: - ClaudeCodeRunner

/// Spawns `claude -p "<prompt>" --output-format stream-json` as a one-shot
/// headless process in the given working directory.
/// Emits ClaudeEvent values and finishes when the process exits.
actor ClaudeCodeRunner {

    private var process: Process?
    private var cancelled = false

    // MARK: - Run

    func run(
        cwd:          URL,
        prompt:       String,
        allowedTools: [String]? = nil,
        maxTurns:     Int       = 50,
        budgetUSD:    Double    = 2.00
    ) -> AsyncStream<ClaudeEvent> {

        AsyncStream { [weak self] continuation in
            Task { [weak self] in
                guard let self else { continuation.finish(); return }
                await self.spawn(cwd: cwd, prompt: prompt,
                                 allowedTools: allowedTools, maxTurns: maxTurns,
                                 budgetUSD: budgetUSD, continuation: continuation)
            }
        }
    }

    // MARK: - Cancel

    func cancel() {
        cancelled = true
        process?.interrupt()
        // Give it 2 s then SIGKILL
        let p = process
        Task {
            try? await Task.sleep(for: .seconds(2))
            p?.terminate()
        }
    }

    // MARK: - Spawn

    private func spawn(
        cwd:          URL,
        prompt:       String,
        allowedTools: [String]?,
        maxTurns:     Int,
        budgetUSD:    Double,
        continuation: AsyncStream<ClaudeEvent>.Continuation
    ) async {

        guard let cli = Config.claudeCodeCLIPath else {
            continuation.yield(.error("claude CLI not found. Install it with: npm install -g @anthropic-ai/claude-code"))
            continuation.finish()
            return
        }

        var args: [String] = [
            "-p", prompt,
            "--output-format", "stream-json",
            "--verbose",
            "--max-turns", "\(maxTurns)",
            "--permission-mode", "bypassPermissions",
        ]
        if let tools = allowedTools, !tools.isEmpty {
            args += ["--allowedTools", tools.joined(separator: ",")]
        }

        let proc = Process()
        proc.executableURL       = URL(fileURLWithPath: cli)
        proc.arguments           = args
        proc.currentDirectoryURL = cwd

        // Inherit env so existing claude auth (OAuth / credentials file) is picked up.
        // We intentionally pass ANTHROPIC_API_KEY through so BYOK users also work.
        // [C1-fix] Removed the API key strip — the CLI needs it for BYOK mode.
        var env = ProcessInfo.processInfo.environment
        if let k = KeychainHelper.get(.githubToken),      !k.isEmpty { env["GITHUB_PERSONAL_ACCESS_TOKEN"] = k }
        if let k = KeychainHelper.get(.composioAPIKey),   !k.isEmpty { env["COMPOSIO_API_KEY"]             = k }
        if let k = KeychainHelper.get(.huggingFaceToken), !k.isEmpty { env["HF_TOKEN"]                     = k }
        // BYOK: pass Anthropic key if set in Keychain (overrides env default)
        if let k = KeychainHelper.get(.anthropicAPIKey),  !k.isEmpty { env["ANTHROPIC_API_KEY"]            = k }
        proc.environment = env

        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardInput  = FileHandle.nullDevice
        proc.standardOutput = stdout
        proc.standardError  = stderr

        self.process = proc

        var sessionId:   String?  = nil
        var totalCost:   Double   = 0
        var startTime:   Date     = Date()
        var accumulated: Double   = 0

        do {
            try proc.run()          // [C7-fix] Propagate launch errors instead of try?
            startTime = Date()
        } catch {
            continuation.yield(.error("Failed to launch claude: \(error.localizedDescription)"))
            continuation.finish()
            return
        }

        // Read stderr asynchronously; clear handler after process exits. [C9-fix]
        let stderrHandle = stderr.fileHandleForReading
        stderrHandle.readabilityHandler = { h in
            let data = h.availableData
            if let line = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .newlines),
               !line.isEmpty {
                print("[ClaudeRunner stderr] \(line)")
            }
        }

        // Stream stdout lines.
        // [A1-fix] Use a detached DispatchQueue block rather than actor-blocking withCheckedContinuation.
        // The block does NOT hold the actor — it communicates back via continuation.yield (thread-safe).
        // [A2-fix] Remove the redundant proc.waitUntilExit() after the drain; the loop already ensures exit.
        // [A11-fix] Use readabilityHandler+semaphore pattern to avoid busy-poll spin.
        var lineBuffer = Data()
        let handle  = stdout.fileHandleForReading
        let sem     = DispatchSemaphore(value: 0)

        handle.readabilityHandler = { h in
            let chunk = h.availableData
            if chunk.isEmpty {
                // EOF — process has exited
                sem.signal()
                return
            }
            lineBuffer.append(chunk)
        }

        // Wait for EOF on a background thread (does not block the actor).
        await withCheckedContinuation { (waitCont: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                sem.wait()
                waitCont.resume()
            }
        }

        // Handler fired for the last time; clear it. [C9-fix]
        handle.readabilityHandler       = nil
        stderrHandle.readabilityHandler = nil

        // Drain any final data
        let remaining = handle.readDataToEndOfFile()
        lineBuffer.append(remaining)

        // Parse all buffered lines
        while let newlineIdx = lineBuffer.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = lineBuffer[lineBuffer.startIndex...newlineIdx]
            lineBuffer   = lineBuffer[lineBuffer.index(after: newlineIdx)...]
            guard let line = String(data: lineData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !line.isEmpty else { continue }

            let events = Self.parseLine(line)
            for event in events {
                if case .usage(_, _, let cost) = event { accumulated += cost }
                continuation.yield(event)
                if accumulated > budgetUSD {
                    continuation.yield(.error("Budget exceeded: $\(String(format: "%.4f", accumulated)) > $\(budgetUSD)"))
                    proc.interrupt()
                }
                if case .sessionId(let sid) = event { sessionId = sid }
                if case .usage(_, _, let c)  = event { totalCost = max(totalCost, c) }
            }
        }

        // [A2-fix] The EOF signal guarantees proc is done; no second waitUntilExit needed.
        let duration = Date().timeIntervalSince(startTime)

        continuation.yield(.done(ClaudeEvent.RunResult(
            exitCode:        proc.terminationStatus,
            totalCostUSD:    totalCost > 0 ? totalCost : accumulated,
            durationSeconds: duration,
            sessionId:       sessionId
        )))
        continuation.finish()
    }

    // MARK: - JSONL parser

    /// Maps one JSONL line to 0..N ClaudeEvent values.
    private static func parseLine(_ line: String) -> [ClaudeEvent] {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return [] }

        switch type {

        case "assistant":
            guard let msg     = json["message"] as? [String: Any],
                  let content = msg["content"]  as? [[String: Any]] else { return [] }
            var events: [ClaudeEvent] = []
            for block in content {
                guard let blockType = block["type"] as? String else { continue }
                if blockType == "text", let text = block["text"] as? String {
                    events.append(.assistantText(text))
                } else if blockType == "tool_use",
                          let name  = block["name"]  as? String,
                          let input = block["input"] as? [String: Any] {
                    // [A1-fix] Serialize input to JSON string so ClaudeEvent stays Sendable.
                    let inputJSON = (try? JSONSerialization.data(withJSONObject: input))
                        .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                    events.append(.toolUse(name: name, inputJSON: inputJSON))
                }
            }
            if let usage = msg["usage"] as? [String: Any] {
                let input  = usage["input_tokens"]  as? Int ?? 0
                let output = usage["output_tokens"] as? Int ?? 0
                let cost   = (json["cost_usd"] as? Double) ?? 0
                if input > 0 || output > 0 {
                    events.append(.usage(inputTokens: input, outputTokens: output, costUSD: cost))
                }
            }
            return events

        case "tool_result":
            let name    = json["name"]     as? String ?? "unknown"
            let content: String
            if let s = json["content"] as? String { content = s }
            else if let arr = json["content"] as? [[String: Any]],
                    let first = arr.first, let text = first["text"] as? String { content = text }
            else { content = "" }
            let isError = json["is_error"] as? Bool ?? false
            return [.toolResult(name: name, output: content, isError: isError)]

        case "result":
            let cost      = (json["total_cost_usd"] as? Double)
                         ?? (json["cost_usd"]       as? Double) ?? 0
            let sid       = json["session_id"] as? String
            var events: [ClaudeEvent] = []
            if let sid { events.append(.sessionId(sid)) }
            events.append(.usage(inputTokens: 0, outputTokens: 0, costUSD: cost))
            return events

        case "system":
            if let sid = json["session_id"] as? String { return [.sessionId(sid)] }
            return []

        default:
            return []
        }
    }
}
