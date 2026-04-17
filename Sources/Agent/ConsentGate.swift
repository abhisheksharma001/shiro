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
        /// Resolved when UI (or Telegram) calls approve/deny.
        let continuation: CheckedContinuation<ApprovalDecision, Never>
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
            // Blocking: suspend until UI resolves.
            let decision = await withCheckedContinuation { cont in
                let approval = PendingApproval(
                    id:            callId,
                    callId:        callId,
                    sessionKey:    sessionKey,
                    toolName:      toolName,
                    input:         input,
                    justification: justification,
                    risk:          risk,
                    continuation:  cont
                )
                pendingApprovals.append(approval)
            }

            // Translate to audit strings.
            let decisionStr: String
            let channel = "ui"
            switch decision {
            case .approved:       decisionStr = "approved"
            case .denied:         decisionStr = "denied"
            case .rememberDeny:   decisionStr = "remembered_deny"
            }
            await audit(callId: callId, sessionKey: sessionKey, toolName: toolName,
                        input: input, risk: risk, decision: decisionStr, channel: channel,
                        justification: justification)

            if case .rememberDeny = decision {
                await persistPolicy(toolName: toolName, policy: "always_deny")
            }
            return decision
        }
    }

    // MARK: - Resolve from UI

    /// Called by ApprovalCardView or TelegramRelay when user taps Approve/Deny/Remember.
    func resolve(callId: String, decision: ApprovalDecision) {
        guard let idx = pendingApprovals.firstIndex(where: { $0.callId == callId }) else { return }
        let approval = pendingApprovals.remove(at: idx)
        approval.continuation.resume(returning: decision)
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
