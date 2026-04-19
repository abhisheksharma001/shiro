import Foundation

// MARK: - TelegramRelay
//
// Runs a long-poll loop against the Telegram Bot API.
// When ConsentGate suspends on a high-risk tool call:
//   1. Sends a formatted message with inline keyboard (✅ Approve / ❌ Deny / 🚫 Never).
//   2. Polls getUpdates; when the user taps a button, resolves the ConsentGate continuation.
//   3. Edits the original message to show the final decision + timestamp.
//
// Thread model:
//   - All public methods are @MainActor (called from ConsentGate).
//   - The poll loop runs as a detached Task; callbackQuery handling dispatches back to MainActor.

@MainActor
final class TelegramRelay {

    // MARK: - Dependencies

    private let token: String
    private let chatId: String
    /// Weak ref set by AppState so we can resolve continuations.
    weak var consentGate: ConsentGate?

    // MARK: - State

    /// callId → messageId of the Telegram message showing that approval request.
    private var pendingMessages: [String: Int] = [:]
    /// Last seen update_id from getUpdates (for offset tracking).
    private var updateOffset: Int = 0
    /// True while the poll loop should keep running.
    private var polling = false
    /// Running poll task — cancelled on `stop()`.
    private var pollTask: Task<Void, Never>?
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
            // Truncate to 800 chars so message doesn't overflow Telegram limits
            prettyInput = str.count > 800 ? String(str.prefix(800)) + "\n…(truncated)" : str
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
            "inline_keyboard": [[
                ["text": "✅ Approve", "callback_data": "approve:\(callId)"],
                ["text": "❌ Deny",    "callback_data": "deny:\(callId)"],
                ["text": "🚫 Never",  "callback_data": "never:\(callId)"]
            ]]
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
        case "approved":       emoji = "✅"
        case "denied":         emoji = "❌"
        case "remembered_deny": emoji = "🚫 (never allow)"
        default:               emoji = "ℹ️"
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
        // Exponential backoff for transient network errors: 1, 2, 4, …, 60s.
        var backoff: TimeInterval = 1
        while await isPollActive() {
            do {
                try Task.checkCancellation()
                let updates = try await getUpdates()
                for update in updates {
                    try Task.checkCancellation()
                    await handleUpdate(update)
                }
                backoff = 1  // reset on success
            } catch is CancellationError {
                return
            } catch {
                print("[TelegramRelay] poll error: \(error.localizedDescription) — backoff \(Int(backoff))s")
                do {
                    try Task.checkCancellation()
                    try await Task.sleep(for: .seconds(backoff))
                } catch {
                    return
                }
                backoff = min(backoff * 2, 60)
            }
        }
    }

    private func isPollActive() async -> Bool { polling }

    private func getUpdates() async throws -> [[String: Any]] {
        let params: [String: Any] = [
            "offset":          updateOffset + 1,
            "timeout":         25,      // long-poll up to 25s
            "allowed_updates": ["callback_query"]
        ]
        let response = try await apiCall(method: "getUpdates", params: params)
        guard let result = response["result"] as? [[String: Any]] else { return [] }

        // Advance offset
        if let last = result.last, let id = last["update_id"] as? Int {
            updateOffset = id
        }
        return result
    }

    private func handleUpdate(_ update: [String: Any]) async {
        guard let callback = update["callback_query"] as? [String: Any],
              let data = callback["data"] as? String,
              let cbId = callback["id"] as? String else { return }

        // Acknowledge the callback immediately so Telegram removes the loading state
        _ = try? await apiCall(method: "answerCallbackQuery", params: ["callback_query_id": cbId])

        // Parse "action:callId"
        let parts = data.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return }
        let action = parts[0]
        let callId = parts[1]

        // Resolve on MainActor
        await MainActor.run { [weak self] in
            guard let self, let gate = self.consentGate else { return }
            let decision: ConsentGate.ApprovalDecision
            switch action {
            case "approve": decision = .approved
            case "deny":    decision = .denied(reason: "Denied via Telegram")
            case "never":   decision = .rememberDeny
            default:        return
            }
            gate.resolve(callId: callId, decision: decision, channel: "telegram")
        }
    }

    // MARK: - HTTP

    private func apiCall(method: String, params: [String: Any]) async throws -> [String: Any] {
        guard let url = URL(string: "https://api.telegram.org/bot\(token)/\(method)") else {
            throw TelegramError.invalidURL
        }
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
