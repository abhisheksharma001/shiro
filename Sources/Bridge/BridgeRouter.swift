import Foundation

/// Common surface exposed by any LLM routing backend.
///
/// Both `ACPBridge` (Node + Claude Agent SDK) and `ClaudeCodeRouter` (spawns the
/// `claude` CLI in headless mode to use a Pro/Max subscription) conform.
/// AgentCoordinator talks to this protocol — it doesn't care which backend ran the query.
@MainActor
protocol BridgeRouter: AnyObject {
    /// Fired for every streaming event from the upstream model.
    var onEvent: ((BridgeEvent) -> Void)? { get set }

    /// Opaque running flag — true once the backend has started successfully.
    var isRunning: Bool { get }

    /// Human-readable label for the current route (shown in Status UI).
    var routeLabel: String { get }

    /// Start the backend. Throws if prerequisites (binary, config) are missing.
    func launch() throws

    /// Gracefully stop the backend and clean up subprocesses.
    func stop()

    /// Send a user query. Results stream back via `onEvent`.
    func query(_ prompt: String,
               sessionKey: String,
               systemPrompt: String?,
               cwd: String?,
               mode: String,
               model: String?,
               resume: String?)

    /// Cancel the active turn for a given session (or `nil` for current/main).
    func interrupt(sessionKey: String?)

    /// Resolve a high-risk tool approval (called by the Consent UI).
    func resolveApproval(callId: String, approved: Bool, denialReason: String?)
}
