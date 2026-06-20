import Foundation

// MARK: - RemoteInbox
//
// Transport-agnostic inbox. Every remote channel (Telegram, HTTP, future PWA)
// normalises its messages into RemoteMessage and calls receive(_:).
//
// RemoteInbox dedupes by msgId, routes to AppState.runRemotePrompt, and replies
// back through the registered RemoteReplySink for that channel.
//
// Thread model: @MainActor — all public methods called from MainActor callers.

// MARK: - Envelope

enum RemoteChannel: String, Sendable {
    case telegram
    case http
    case pwa        // reserved for future WebSocket companion
}

struct RemoteMessage: Identifiable, Sendable {
    let id: String              // dedupe key (Telegram update_id, HTTP request UUID, etc.)
    let channel: RemoteChannel
    let senderId: String        // chat_id, IP, etc.
    let text: String
    let timestamp: Date
    let replyToken: String?     // opaque; used by sink to route the reply back
}

// MARK: - Reply sink protocol

/// A channel-specific sink that knows how to send reply chunks back.
/// Conforming types: TelegramRelay (phase 1), HTTPRemoteServer (phase 6).
@MainActor
protocol RemoteReplySink: AnyObject {
    /// Called with incremental text while the response is streaming.
    func streamChunk(_ text: String, replyToken: String?) async
    /// Called once when streaming is complete.
    func streamFinished(replyToken: String?, finalText: String) async
    /// Called if the run fails.
    func streamError(_ message: String, replyToken: String?) async
}

// MARK: - RemoteInbox

@MainActor
final class RemoteInbox: ObservableObject {

    // MARK: Published (debug / status UI)
    @Published private(set) var recent: [RemoteMessage] = []   // last 50 for debug tab
    @Published private(set) var activeChannel: RemoteChannel?

    // MARK: Private
    private var sinks: [RemoteChannel: RemoteReplySink] = [:]
    private var seenIds: Set<String> = []            // dedup window
    private weak var appState: AppState?
    private var activeTask: Task<Void, Never>?

    // MARK: Init

    init(appState: AppState) {
        self.appState = appState
    }

    // MARK: Registration

    func register(_ sink: RemoteReplySink, for channel: RemoteChannel) {
        sinks[channel] = sink
        print("[RemoteInbox] registered sink for channel: \(channel.rawValue)")
    }

    // MARK: Receive

    /// Called by any transport when a new user message arrives.
    func receive(_ msg: RemoteMessage) async {
        // Dedupe — Telegram can deliver the same update twice on reconnect.
        guard !seenIds.contains(msg.id) else { return }
        seenIds.insert(msg.id)
        if seenIds.count > 500 { seenIds.removeFirst() }

        // Keep debug list trimmed to 50.
        recent.append(msg)
        if recent.count > 50 { recent.removeFirst() }

        guard let appState else { return }
        let sink = sinks[msg.channel]

        // Guard: one task at a time. If busy, tell the sender.
        guard activeTask == nil || activeTask?.isCancelled == true else {
            await sink?.streamError(
                "⚠️ Already processing a request. Send /cancel to stop it.",
                replyToken: msg.replyToken
            )
            return
        }

        activeChannel = msg.channel

        activeTask = Task { [weak self, weak appState] in
            guard let appState else { return }

            var accumulated = ""

            let stream = await appState.runRemotePrompt(msg.text, source: msg.channel.rawValue)
            for await chunk in stream {
                accumulated += chunk
                await sink?.streamChunk(chunk, replyToken: msg.replyToken)
            }

            await sink?.streamFinished(replyToken: msg.replyToken, finalText: accumulated)

            await MainActor.run { [weak self] in
                self?.activeChannel = nil
                self?.activeTask = nil
            }
        }
    }

    // MARK: Cancel

    func cancelActive() {
        activeTask?.cancel()
        activeTask = nil
        activeChannel = nil
    }
}
