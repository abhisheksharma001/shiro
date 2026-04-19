import Foundation
import GRDB

// MARK: - ConsentGate
//
// The approval layer between the model's tool_use requests and actual execution.
//
// Decision flow:
//   1. Check ToolPolicy table — always_allow | always_deny → immediate decision.
//   2. Check risk level:
//        low  → auto_approved (no UI shown)
//        med  → auto_approved (future: toast with 3s veto)
//        high → present blocking ApprovalCard in UI; wait for resolveApproval()
//   3. Log every decision to tool_approvals table.
//   4. After "remember_deny", write a ToolPolicy row so future calls are instant.

@MainActor
final class ConsentGate: ObservableObject {

    // MARK: - Pending approval

    struct PendingApproval: Identifiable {
        let id: String             // = callId
        let callId: String
        let sessionKey: String
        let toolName: String
        let input: [String: Any]
        let justification: String?
        let risk: ToolRisk
        let requestedAt: Date = Date()
        /// Resolved when UI (Telegram, or the timeout watchdog) calls approve/deny.
        /// Wrapped so only the first caller wins.
        let continuation: Resumer
    }

    /// Wraps a CheckedContinuation so exactly one of {user, timeout} resumes it.
    final class Resumer: @unchecked Sendable {
        private let lock = NSLock()
        private var cont: CheckedContinuation<ApprovalDecision, Never>?
        init(_ c: CheckedContinuation<ApprovalDecision, Never>) { self.cont = c }
        func resume(_ decision: ApprovalDecision) {
            lock.lock(); defer { lock.unlock() }
            guard let c = cont else { return }
            cont = nil
            c.resume(returning: decision)
        }
    }

    /// Builder helper used inside withCheckedContinuation closures.
    private final class ContinuationResumer {
        let resumer: Resumer
        init(continuation: CheckedContinuation<ApprovalDecision, Never>) {
            self.resumer = Resumer(continuation)
        }
        func proxy() -> Resumer { resumer }
        func resume(_ d: ApprovalDecision) { resumer.resume(d) }
    }

    enum ApprovalDecision {
        case approved
        case denied(reason: String?)
        case rememberDeny
    }

    @Published var pendingApprovals: [PendingApproval] = []

    private let db: ShiroDatabase
    /// In-memory policy cache — loaded from DB on init, updated on remember_deny.
    private var policyCache: [String: String] = [:]   // toolName → "always_allow" | "always_deny" | "ask"
    /// Optional Telegram relay for remote approval when not at the Mac.
    var telegramRelay: TelegramRelay?
    /// Tracks which channel resolved each callId, so audit logs the right channel.
    private var resolveChannel: [String: String] = [:]

    // MARK: - Init

    init(database: ShiroDatabase) {
        self.db = database
        Task { await loadPolicies() }
    }

    private func loadPolicies() async {
        do {
            let rows = try await db.pool.read { conn in
                try ToolPolicy.fetchAll(conn)
            }
            for row in rows {
                policyCache[row.toolName] = row.policy
            }
            print("[ConsentGate] loaded \(rows.count) tool policies")
        } catch {
            print("[ConsentGate] policy load error: \(error)")
        }
    }

    // MARK: - Main entry point

    /// Called by ACPBridge before executing any tool. Returns .approved or .denied.
    /// This method suspends (blocks) for high-risk tools until the user decides.
    func evaluate(
        callId:        String,
        sessionKey:    String,
        toolName:      String,
        input:         [String: Any],
        justification: String?,
        risk:          ToolRisk
    ) async -> ApprovalDecision {

        // 1. Policy override check.
        let effectivePolicy = resolvePolicy(for: toolName)
        switch effectivePolicy {
        case "always_allow":
            await audit(callId: callId, sessionKey: sessionKey, toolName: toolName,
                        input: input, risk: risk, decision: "auto_approved", channel: "auto",
                        justification: "always_allow policy")
            return .approved
        case "always_deny":
            await audit(callId: callId, sessionKey: sessionKey, toolName: toolName,
                        input: input, risk: risk, decision: "denied", channel: "auto",
                        justification: "always_deny policy")
            return .denied(reason: "Blocked by always_deny policy for \(toolName)")
        default:
            break
        }

        // 2. Risk-based routing.
        switch risk {
        case .low:
            await audit(callId: callId, sessionKey: sessionKey, toolName: toolName,
                        input: input, risk: risk, decision: "auto_approved", channel: "auto",
                        justification: nil)
            return .approved

        case .med:
            // Future: short toast with veto. For now auto-approve like low.
            await audit(callId: callId, sessionKey: sessionKey, toolName: toolName,
                        input: input, risk: risk, decision: "auto_approved", channel: "auto",
                        justification: nil)
            return .approved

        case .high:
            // Blocking: suspend until UI or Telegram resolves — with a hard timeout
            // so a dismissed dialog or offline Telegram doesn't deadlock the agent.
            let decision = await withCheckedContinuation { (cont: CheckedContinuation<ApprovalDecision, Never>) in
                // Single-shot resume guard — prevents double-resume if both the timeout
                // and the user resolve simultaneously.
                let resumer = ContinuationResumer(continuation: cont)

                let approval = PendingApproval(
                    id:            callId,
                    callId:        callId,
                    sessionKey:    sessionKey,
                    toolName:      toolName,
                    input:         input,
                    justification: justification,
                    risk:          risk,
                    continuation:  resumer.proxy()
                )
                pendingApprovals.append(approval)

                // Fire Telegram in parallel (non-blocking) — user may not be at Mac.
                if let relay = telegramRelay {
                    Task {
                        await relay.sendApprovalCard(
                            callId:        callId,
                            toolName:      toolName,
                            sessionKey:    sessionKey,
                            input:         input,
                            justification: justification,
                            risk:          risk.rawValue
                        )
                    }
                }

                // Timeout watchdog — 5 minutes, matches Config.agentTimeoutSeconds.
                let timeout = Config.approvalTimeoutSeconds
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    guard let self else { return }
                    // If still pending, remove and auto-deny.
                    if let idx = self.pendingApprovals.firstIndex(where: { $0.callId == callId }) {
                        self.pendingApprovals.remove(at: idx)
                        self.resolveChannel[callId] = "timeout"
                        resumer.resume(.denied(reason: "Approval timed out after \(Int(timeout))s"))
                    }
                }
            }

            // Determine which channel resolved (UI default, Telegram if relay set it).
            let channel = resolveChannel.removeValue(forKey: callId) ?? "ui"

            // Translate to audit strings.
            let decisionStr: String
            switch decision {
            case .approved:       decisionStr = "approved"
            case .denied:         decisionStr = "denied"
            case .rememberDeny:   decisionStr = "remembered_deny"
            }

            await audit(callId: callId, sessionKey: sessionKey, toolName: toolName,
                        input: input, risk: risk, decision: decisionStr, channel: channel,
                        justification: justification)

            // Edit Telegram message to show result (if relay is wired).
            if let relay = telegramRelay {
                Task { await relay.markResolved(callId: callId, decision: decisionStr) }
            }

            if case .rememberDeny = decision {
                await persistPolicy(toolName: toolName, policy: "always_deny")
            }
            return decision
        }
    }

    // MARK: - Resolve from UI

    /// Called by ApprovalCardView or TelegramRelay when user taps Approve/Deny/Remember.
    /// `channel` is "ui" (default) or "telegram" — recorded in the audit log.
    func resolve(callId: String, decision: ApprovalDecision, channel: String = "ui") {
        guard let idx = pendingApprovals.firstIndex(where: { $0.callId == callId }) else { return }
        resolveChannel[callId] = channel
        let approval = pendingApprovals.remove(at: idx)
        approval.continuation.resume(decision)
    }

    // MARK: - Policy management

    private func resolvePolicy(for toolName: String) -> String {
        // Exact match first.
        if let p = policyCache[toolName] { return p }
        // Prefix wildcard: "shell_exec" matches "shell_exec:*"  (not currently used, but ready).
        return "ask"
    }

    func setPolicy(toolName: String, policy: String) async {
        await persistPolicy(toolName: toolName, policy: policy)
    }

    private func persistPolicy(toolName: String, policy: String) async {
        policyCache[toolName] = policy
        let row = ToolPolicy(toolName: toolName, policy: policy, updatedAt: Date())
        do {
            try await db.pool.write { conn in
                try row.insert(conn, onConflict: .replace)
            }
        } catch {
            print("[ConsentGate] persistPolicy error: \(error)")
        }
    }

    // MARK: - Audit

    private func audit(
        callId:        String,
        sessionKey:    String,
        toolName:      String,
        input:         [String: Any],
        risk:          ToolRisk,
        decision:      String,
        channel:       String,
        justification: String?
    ) async {
        let row = ToolApproval.new(
            callId:        callId,
            sessionKey:    sessionKey,
            toolName:      toolName,
            input:         input,
            riskLevel:     risk.rawValue,
            decision:      decision,
            channel:       channel,
            justification: justification
        )
        do {
            try await db.pool.write { conn in try row.insert(conn) }
        } catch {
            print("[ConsentGate] audit error: \(error)")
        }
    }

    // MARK: - Stats / debug

    func recentApprovals(limit: Int = 20) async -> [ToolApproval] {
        (try? await db.pool.read { conn in
            try ToolApproval
                .order(Column("created_at").desc)
                .limit(limit)
                .fetchAll(conn)
        }) ?? []
    }
}
