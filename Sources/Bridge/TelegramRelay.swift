import Foundation

// MARK: - TelegramRelay
//
// Runs a long-poll loop against the Telegram Bot API.
//
// Approval flow (existing):
//   1. ConsentGate calls sendApprovalCard() → shows inline buttons.
//   2. User taps button → callback_query → resolves ConsentGate continuation.
//
// Bidirectional chat (Phase 1):
//   3. Free-text messages → runRemotePrompt on AppState → stream reply back.
//   4. Slash commands: /start /cancel /model /status /code
//
// Thread model:
//   - All public methods are @MainActor (called from ConsentGate / AppState).
//   - The poll loop runs as a detached Task; dispatch back to MainActor as needed.

@MainActor
final class TelegramRelay {

    // MARK: - Dependencies

    private let token: String
    private let chatId: String
    /// Weak ref set by AppState so we can resolve continuations.
    weak var consentGate: ConsentGate?
    /// Weak ref set by AppState so we can run prompts.
    weak var appState: AppState?

    // MARK: - State

    /// callId → messageId of the Telegram message showing that approval request.
    private var pendingMessages: [String: Int] = [:]
    /// planId → CodingPlan — stored while waiting for Telegram approve/cancel button.
    private var pendingPlans: [String: CodingPlan] = [:]
    /// Last seen update_id from getUpdates (for offset tracking).
    private var updateOffset: Int = 0
    /// True while the poll loop should keep running.
    private var polling = false
    /// Running poll task — cancelled on `stop()`.
    private var pollTask: Task<Void, Never>?
    /// Active streaming task — cancelled on /cancel.
    private var activeStreamTask: Task<Void, Never>?
    /// Instance-owned URLSession for all Telegram HTTP calls.
    private let wsSession: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest  = 35   // getUpdates uses long-poll=25s
        c.timeoutIntervalForResource = 45
        return URLSession(configuration: c)
    }()

    // MARK: - Init

    init(token: String, chatId: String) {
        self.token = token
        self.chatId = chatId
    }

    // MARK: - Lifecycle

    func start() {
        guard !polling else { return }
        polling = true
        pollTask = Task { [weak self] in
            await self?.pollLoop()
        }
        print("[TelegramRelay] started — chatId: \(chatId)")
    }

    func stop() {
        polling = false
        pollTask?.cancel()
        pollTask = nil
        activeStreamTask?.cancel()
        activeStreamTask = nil
    }

    // MARK: - Send approval card

    /// Called by ConsentGate when a high-risk tool is waiting for approval.
    func sendApprovalCard(
        callId:        String,
        toolName:      String,
        sessionKey:    String,
        input:         [String: Any],
        justification: String?,
        risk:          String
    ) async {
        let prettyInput: String
        if let data = try? JSONSerialization.data(withJSONObject: input, options: .prettyPrinted),
           let str = String(data: data, encoding: .utf8) {
            prettyInput = str.count > 800 ? String(str.prefix(800)) + "\n...(truncated)" : str
        } else {
            prettyInput = input.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
        }

        let riskEmoji = risk == "high" ? "🔴" : risk == "med" ? "🟡" : "🟢"
        let justText = justification.map { "\n💬 _\($0)_" } ?? ""

        let text = """
⚠️ *SHIRO — ACTION APPROVAL REQUIRED*

\(riskEmoji) Risk: *\(risk.uppercased())*
🔧 Tool: `\(toolName)`
🔑 Session: `\(sessionKey)`\(justText)

*Arguments:*
```
\(prettyInput)
```

Tap a button to decide ↓
"""

        let keyboard: [String: Any] = [
            "inline_keyboard": [
                [
                    ["text": "✅ Approve", "callback_data": "approve:\(callId)"],
                    ["text": "❌ Deny",    "callback_data": "deny:\(callId)"]
                ],
                [
                    ["text": "🛡 Always", "callback_data": "always:\(callId)"],
                    ["text": "🚫 Never",  "callback_data": "never:\(callId)"]
                ]
            ]
        ]

        do {
            let response = try await apiCall(method: "sendMessage", params: [
                "chat_id":    chatId,
                "text":       text,
                "parse_mode": "Markdown",
                "reply_markup": keyboard
            ])
            if let result = response["result"] as? [String: Any],
               let messageId = result["message_id"] as? Int {
                pendingMessages[callId] = messageId
            }
        } catch {
            print("[TelegramRelay] sendApprovalCard error: \(error.localizedDescription)")
        }
    }

    /// Edit the sent message to show the final decision (removes the inline keyboard).
    func markResolved(callId: String, decision: String) async {
        guard let messageId = pendingMessages.removeValue(forKey: callId) else { return }

        let emoji: String
        switch decision {
        case "approved":         emoji = "✅"
        case "denied":           emoji = "❌"
        case "remembered_deny":  emoji = "🚫 (never allow)"
        case "remembered_allow": emoji = "🛡 (always allow)"
        default:                 emoji = "ℹ️"
        }

        let text = "\(emoji) *\(decision.uppercased())* — resolved at \(timestamp())"
        _ = try? await apiCall(method: "editMessageText", params: [
            "chat_id":    chatId,
            "message_id": messageId,
            "text":       text,
            "parse_mode": "Markdown"
        ])
    }

    /// Send a plain notification (non-blocking, used for audit trail / status pings).
    func notify(_ text: String) async {
        _ = try? await apiCall(method: "sendMessage", params: [
            "chat_id":    chatId,
            "text":       text,
            "parse_mode": "Markdown"
        ])
    }

    // MARK: - Poll loop

    private func pollLoop() async {
        var backoff: TimeInterval = 1
        while await isPollActive() {
            do {
                try Task.checkCancellation()
                let updates = try await getUpdates()
                for update in updates {
                    try Task.checkCancellation()
                    await handleUpdate(update)
                }
                backoff = 1
            } catch is CancellationError {
                return
            } catch {
                print("[TelegramRelay] poll error: \(error.localizedDescription) — backoff \(Int(backoff))s")
                do {
                    try Task.checkCancellation()
                    try await Task.sleep(for: .seconds(backoff))
                } catch { return }
                backoff = min(backoff * 2, 60)
            }
        }
    }

    private func isPollActive() async -> Bool { polling }

    private func getUpdates() async throws -> [[String: Any]] {
        let params: [String: Any] = [
            "offset":          updateOffset + 1,
            "timeout":         25,
            "allowed_updates": ["callback_query", "message"]   // Phase 1: include message
        ]
        let response = try await apiCall(method: "getUpdates", params: params)
        guard let result = response["result"] as? [[String: Any]] else { return [] }
        if let last = result.last, let id = last["update_id"] as? Int {
            updateOffset = id
        }
        return result
    }

    // MARK: - Update handler

    private func handleUpdate(_ update: [String: Any]) async {

        // ── Inline-button callback ─────────────────────────────────────────
        if let callback = update["callback_query"] as? [String: Any],
           let data = callback["data"] as? String,
           let cbId = callback["id"] as? String {
            _ = try? await apiCall(method: "answerCallbackQuery", params: ["callback_query_id": cbId])
            let parts = data.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return }
            let action = parts[0], value = parts[1]

            // ── Coding plan approval ──────────────────────────────────────
            if action == "code_execute" || action == "code_cancel" {
                guard let plan = pendingPlans.removeValue(forKey: value) else { return }
                // Edit the plan preview message
                if let msgId = pendingMessages.removeValue(forKey: "plan_\(value)") {
                    let resultText = action == "code_execute"
                        ? "✅ *Executing plan…*\nOpening VS Code + Claude Code."
                        : "❌ *Cancelled.*"
                    _ = try? await apiCall(method: "editMessageText", params: [
                        "chat_id":    chatId,
                        "message_id": msgId,
                        "text":       resultText,
                        "parse_mode": "Markdown"
                    ])
                }
                if action == "code_execute" {
                    Task { [weak self] in
                        guard let orch = self?.appState?.codingOrchestrator else { return }
                        do {
                            try await orch.executePlan(plan)
                            await self?.notify("✅ VS Code opened. Claude Code will start automatically when the workspace loads.")
                        } catch {
                            await self?.notify("❌ Execute failed: \(error.localizedDescription)")
                        }
                    }
                }
                return
            }

            // ── Consent gate approval (existing flow) ─────────────────────
            await MainActor.run { [weak self] in
                guard let self, let gate = self.consentGate else { return }
                let decision: ConsentGate.ApprovalDecision
                switch action {
                case "approve": decision = .approved
                case "deny":    decision = .denied(reason: "Denied via Telegram")
                case "never":   decision = .rememberDeny
                case "always":  decision = .rememberAllow
                default: return
                }
                gate.resolve(callId: value, decision: decision, channel: "telegram")
            }
            return
        }

        // ── Free-text message (Phase 1) ────────────────────────────────────
        guard let message  = update["message"] as? [String: Any],
              let chat     = message["chat"] as? [String: Any],
              let chatIdInt = chat["id"] as? Int,
              String(chatIdInt) == self.chatId,
              let text     = message["text"] as? String else { return }

        if text.hasPrefix("/") {
            await handleCommand(text)
        } else {
            await handleIncomingText(text)
        }
    }

    // MARK: - Slash commands

    private func handleCommand(_ text: String) async {
        let parts = text.split(separator: " ", maxSplits: 1).map(String.init)
        let cmd   = parts[0].lowercased()
        let args  = parts.count > 1 ? parts[1] : ""

        switch cmd {
        case "/start":
            await notify("""
👋 *Shiro is online.*

Send me a message and I'll run it through the agent.

*Commands:*
`/status` — current model + last task
`/model sonnet|opus|haiku` — switch model
`/cancel` — stop running task
`/code <task>` — launch Claude Code on a task _(coming in Phase 3)_
""")

        case "/cancel":
            activeStreamTask?.cancel()
            activeStreamTask = nil
            await MainActor.run { [weak self] in
                guard let self, let appState = self.appState else { return }
                appState.agentCoordinator?.bridge?.interrupt(sessionKey: "main")
                appState.acpBridge?.interrupt(sessionKey: "main")
                appState.isRemoteProcessing = false
                appState.isProcessing       = false
                appState.isTypingMain       = false
                appState.agentStatus        = .idle
            }
            await notify("🛑 Task cancelled.")

        case "/status":
            await MainActor.run { [weak self] in
                guard let self, let appState = self.appState else { return }
                let model   = Config.activeModel ?? "default"
                let running = appState.isRemoteProcessing ? "🔄 Running" : "💤 Idle"
                let route   = appState.activeRouteMode.displayName
                Task { [weak self] in
                    await self?.notify("*Status:* \(running)\n*Route:* \(route)\n*Model:* `\(model)`")
                }
            }

        case "/model":
            let name = args.trimmingCharacters(in: .whitespaces).lowercased()
            let valid = ["sonnet", "opus", "haiku",
                         "claude-sonnet-4-6", "claude-opus-4-6", "claude-haiku-4-5"]
            if name.isEmpty || !valid.contains(where: { name.contains($0) }) {
                await notify("Usage: `/model sonnet|opus|haiku`")
                return
            }
            let resolved: String
            if name.contains("opus")   { resolved = "claude-opus-4-6" }
            else if name.contains("haiku") { resolved = "claude-haiku-4-5" }
            else                       { resolved = "claude-sonnet-4-6" }
            Config.setActiveModel(resolved)
            await notify("✅ Model set to `\(resolved)`")

        case "/code":
            if args.isEmpty {
                await notify("Usage: `/code <task description>`")
                return
            }
            guard let orch = appState?.codingOrchestrator else {
                await notify("❌ CodingOrchestrator not ready.")
                return
            }
            await notify("⚙️ _Planning coding task…_")
            do {
                let plan = try await orch.plan(task: args)
                let preview = """
*Plan ready*
📁 Project: `\(plan.workspaceName)`
🌿 Branch: `\(plan.branchName)`
⚙️ Mode: `\(plan.mode.rawValue)`
💰 Budget: $\(String(format: "%.2f", plan.maxCostUSD))

\(plan.prompt.prefix(300))
"""
                // Send plan + inline approve/skip buttons
                let keyboard: [String: Any] = [
                    "inline_keyboard": [[
                        ["text": "✅ Execute", "callback_data": "code_execute:\(plan.id)"],
                        ["text": "❌ Cancel",  "callback_data": "code_cancel:\(plan.id)"]
                    ]]
                ]
                let resp = try? await apiCall(method: "sendMessage", params: [
                    "chat_id":      chatId,
                    "text":         preview,
                    "parse_mode":   "Markdown",
                    "reply_markup": keyboard
                ])
                // Store plan in orchestrator for callback resolution
                await MainActor.run {
                    orch.activePlans[plan.branchName] = plan
                    // Store for button callback lookup: reuse pendingMessages with plan.id key
                }
                if let msgId = (resp?["result"] as? [String: Any])?["message_id"] as? Int {
                    pendingMessages["plan_\(plan.id)"] = msgId
                }
                // Store plan reference for callback
                pendingPlans[plan.id] = plan
            } catch {
                await notify("❌ Planning failed: \(error.localizedDescription)")
            }

        default:
            await notify("Unknown command: `\(cmd)`. Send `/start` for help.")
        }
    }

    // MARK: - Text handler with streaming reply

    private func handleIncomingText(_ text: String) async {
        guard let appState else {
            await notify("❌ AppState not wired. Contact developer.")
            return
        }

        // Send "working" placeholder and capture its message_id for live edits
        var replyMsgId: Int? = nil
        do {
            let resp = try await apiCall(method: "sendMessage", params: [
                "chat_id":    chatId,
                "text":       "⏳ _Working…_",
                "parse_mode": "Markdown"
            ])
            if let result = resp["result"] as? [String: Any],
               let msgId = result["message_id"] as? Int {
                replyMsgId = msgId
            }
        } catch {
            print("[TelegramRelay] could not send working placeholder: \(error)")
        }

        let buffer = StreamBuffer()
        let msgIdCapture = replyMsgId

        activeStreamTask = Task { [weak self] in
            guard let self else { return }

            var accumulated = ""
            var lastEdit    = Date.distantPast

            let stream = await appState.runRemotePrompt(text, source: "telegram")

            for await chunk in stream {
                accumulated += chunk
                let now = Date()
                let shouldFlush = accumulated.count - (await buffer.lastFlushedLength) > 80
                    || now.timeIntervalSince(lastEdit) > 0.5

                if shouldFlush, let msgId = msgIdCapture {
                    let snap = accumulated
                    await buffer.setLastFlushedLength(snap.count)
                    lastEdit = now
                    _ = try? await self.apiCall(method: "editMessageText", params: [
                        "chat_id":    self.chatId,
                        "message_id": msgId,
                        "text":       snap.count > 4000 ? "…" + String(snap.suffix(3900)) : snap,
                        "parse_mode": "Markdown"
                    ])
                }
            }

            // Final edit — ensure the complete message is shown
            if let msgId = msgIdCapture, !accumulated.isEmpty {
                let finalText = accumulated.count > 4000
                    ? "…" + String(accumulated.suffix(3900))
                    : accumulated
                _ = try? await self.apiCall(method: "editMessageText", params: [
                    "chat_id":    self.chatId,
                    "message_id": msgId,
                    "text":       finalText.isEmpty ? "_(no response)_" : finalText,
                    "parse_mode": "Markdown"
                ])
            }
        }

        await activeStreamTask?.value
        activeStreamTask = nil
    }

    // MARK: - HTTP

    private func telegramURL(_ method: String) -> URL? {
        let encoded = token.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? token
        return URL(string: "https://api.telegram.org/bot\(encoded)/\(method)")
    }

    private func apiCall(method: String, params: [String: Any]) async throws -> [String: Any] {
        guard let url = telegramURL(method) else { throw TelegramError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        request.httpBody = try JSONSerialization.data(withJSONObject: params)
        let (data, response) = try await wsSession.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw TelegramError.noResponse }
        guard http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "(empty)"
            throw TelegramError.httpError(http.statusCode, body)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TelegramError.decodeFailed
        }
        return json
    }

    // MARK: - Helpers

    private func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: Date())
    }
}

// MARK: - RemoteReplySink conformance (Phase 2)
//
// When messages arrive via RemoteInbox, chunks are delivered here instead of
// being driven directly by handleIncomingText. Both paths still work — direct
// path is used when TelegramRelay handles messages itself (backward compat).

extension TelegramRelay: RemoteReplySink {

    func streamChunk(_ text: String, replyToken: String?) async {
        // replyToken is the message_id as a String when sent from RemoteInbox path.
        // Chunk delivery handled by handleIncomingText's own streaming loop in direct path.
        // For RemoteInbox path, we accumulate and edit in streamFinished.
        // Lightweight no-op here; heavy lifting done in streamFinished.
        _ = replyToken  // suppress unused warning — used in streamFinished
    }

    func streamFinished(replyToken: String?, finalText: String) async {
        guard let token = replyToken, let msgId = Int(token) else {
            // No existing message — send fresh.
            await notify(finalText.isEmpty ? "_(no response)_" : finalText)
            return
        }
        let text = finalText.count > 4000
            ? "..." + String(finalText.suffix(3900))
            : finalText
        _ = try? await apiCall(method: "editMessageText", params: [
            "chat_id":    chatId,
            "message_id": msgId,
            "text":       text.isEmpty ? "_(no response)_" : text,
            "parse_mode": "Markdown"
        ])
    }

    func streamError(_ message: String, replyToken: String?) async {
        if let token = replyToken, let msgId = Int(token) {
            _ = try? await apiCall(method: "editMessageText", params: [
                "chat_id":    chatId,
                "message_id": msgId,
                "text":       message,
                "parse_mode": "Markdown"
            ])
        } else {
            await notify(message)
        }
    }
}

// MARK: - Stream buffer (tracks flush position, thread-safe via actor)

private actor StreamBuffer {
    private var _lastFlushedLength: Int = 0
    var lastFlushedLength: Int { _lastFlushedLength }
    func setLastFlushedLength(_ n: Int) { _lastFlushedLength = n }
}

// MARK: - Errors

enum TelegramError: LocalizedError {
    case invalidURL
    case noResponse
    case httpError(Int, String)
    case decodeFailed

    var errorDescription: String? {
        switch self {
        case .invalidURL:              return "TelegramRelay: invalid URL"
        case .noResponse:             return "TelegramRelay: no HTTP response"
        case .httpError(let c, let b): return "TelegramRelay: HTTP \(c) — \(b.prefix(200))"
        case .decodeFailed:           return "TelegramRelay: JSON decode failed"
        }
    }
}
