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
        case rememberAllow
    }

    // MARK: - Policy entry (for UI)

    struct PolicyEntry: Identifiable {
        var id: String { toolName }
        let toolName: String
        let policy: String        // "always_allow" | "always_deny"
        let updatedAt: Date
    }

    @Published var pendingApprovals: [PendingApproval] = []
    /// Published list of saved policies — drives PoliciesTab in Settings.
    @Published private(set) var policies: [PolicyEntry] = []

    private let db: ShiroDatabase
    /// In-memory policy cache — loaded from DB on init, updated on remember_deny.
    private var policyCache: [String: String] = [:]   // toolName → "always_allow" | "always_deny" | "ask"
    /// Optional Telegram relay for remote approval when not at the Mac.
    var telegramRelay: TelegramRelay?
    /// Tracks which channel resolved each callId, so audit logs the right channel.
    private var resolveChannel:  [String: String] = [:]
    // [A4-fix] Store timeout tasks so they can be cancelled when the user resolves early.
    private var timeoutTasks:    [String: Task<Void, Never>] = [:]

    /// Per-workspace auto-approve risk threshold (from .shiro/workspace.toml).
    /// When non-nil, actions at or below this risk level are auto-approved without
    /// showing a veto toast. CodingOrchestrator sets this when a plan starts and
    /// clears it (sets to nil) when the plan finishes.
    var workspaceAutoApproveRisk: ToolRisk? = nil

    // Veto results from the 3-second medium-risk toast.
    private var vetoResults: [String: ApprovalDecision] = [:]

    /// Published so the UI can show an active veto toast.
    @Published var activeVetoToasts: [VetoToast] = []

    struct VetoToast: Identifiable {
        let id: String       // callId
        let toolName: String
        var secondsLeft: Int = 3
    }

    // MARK: - Init

    init(database: ShiroDatabase) {
        self.db = database
        Task { await reloadPolicies() }
    }

    /// Re-queries the DB and repopulates both `policyCache` and `policies`.
    func reloadPolicies() async {
        do {
            let rows = try await db.pool.read { conn in
                try ToolPolicy.fetchAll(conn)
            }
            policyCache.removeAll()
            for row in rows {
                policyCache[row.toolName] = row.policy
            }
            policies = rows
                .sorted { $0.updatedAt > $1.updatedAt }
                .map { PolicyEntry(toolName: $0.toolName, policy: $0.policy, updatedAt: $0.updatedAt) }
            print("[ConsentGate] loaded \(rows.count) tool policies")
        } catch {
            print("[ConsentGate] policy load error: \(error)")
        }
    }

    /// Deletes a saved policy from DB + cache so the tool goes back to asking.
    func revokePolicy(toolName: String) async {
        policyCache.removeValue(forKey: toolName)
        policies.removeAll { $0.toolName == toolName }
        do {
            try await db.pool.write { conn in
                try conn.execute(sql: "DELETE FROM tool_policies WHERE tool_name = ?", arguments: [toolName])
            }
        } catch {
            print("[ConsentGate] revokePolicy error: \(error)")
        }
    }

    /// Public interface to manually set a policy (e.g., from Settings UI).
    func setPolicyManual(toolName: String, policy: String) async {
        await persistPolicy(toolName: toolName, policy: policy)
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

        // 2a. Workspace preset override: if the active workspace's auto_approve_risk
        // covers this tool's risk level, auto-approve without showing any UI.
        // Example: auto_approve_risk = "med" silently approves both .low and .med tools.
        if let wsThreshold = workspaceAutoApproveRisk, risk <= wsThreshold {
            await audit(callId: callId, sessionKey: sessionKey, toolName: toolName,
                        input: input, risk: risk, decision: "auto_approved", channel: "workspace_preset",
                        justification: "workspace.toml auto_approve_risk=\(wsThreshold.rawValue)")
            return .approved
        }

        // 2b. Risk-based routing.
        switch risk {
        case .low:
            await audit(callId: callId, sessionKey: sessionKey, toolName: toolName,
                        input: input, risk: risk, decision: "auto_approved", channel: "auto",
                        justification: nil)
            return .approved

        case .med:
            if Config.askBeforeMediumRisk {
                // Treat same as high — block on user approval.
                return await awaitUserApproval(
                    callId: callId, sessionKey: sessionKey, toolName: toolName,
                    input: input, justification: justification, risk: risk)
            }
            // Auto-approve, but optionally show a 3-second veto toast.
            if Config.showMediumRiskVetoToast {
                await fireMediumRiskVetoToast(
                    toolName: toolName, callId: callId,
                    sessionKey: sessionKey, input: input, risk: risk,
                    justification: justification)
                if let vetoed = vetoResults[callId], case .denied = vetoed {
                    vetoResults.removeValue(forKey: callId)
                    await audit(callId: callId, sessionKey: sessionKey, toolName: toolName,
                                input: input, risk: risk, decision: "denied", channel: "veto",
                                justification: "3-second veto triggered")
                    return .denied(reason: "Vetoed via toast")
                }
                vetoResults.removeValue(forKey: callId)
            }
            await audit(callId: callId, sessionKey: sessionKey, toolName: toolName,
                        input: input, risk: risk, decision: "auto_approved", channel: "auto",
                        justification: nil)
            return .approved

        case .high:
            return await awaitUserApproval(
                callId: callId, sessionKey: sessionKey, toolName: toolName,
                input: input, justification: justification, risk: risk)
        }
    }

    /// Blocking helper — suspends until user (UI or Telegram) resolves the approval card,
    /// or the timeout watchdog fires.
    private func awaitUserApproval(
        callId:        String,
        sessionKey:    String,
        toolName:      String,
        input:         [String: Any],
        justification: String?,
        risk:          ToolRisk
    ) async -> ApprovalDecision {
        let decision = await withCheckedContinuation { (cont: CheckedContinuation<ApprovalDecision, Never>) in
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

            // Fire Telegram in parallel (non-blocking).
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

            // [A4-fix] Store the timeout task so resolve() can cancel it before the timer fires.
            // [C8-fix] Use Task.sleep(for:) with Duration — avoids UInt64 overflow for large intervals.
            let timeout = Config.approvalTimeoutSeconds
            let timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                guard let self, !Task.isCancelled else { return }
                if let idx = self.pendingApprovals.firstIndex(where: { $0.callId == callId }) {
                    self.pendingApprovals.remove(at: idx)
                    self.resolveChannel[callId] = "timeout"
                    self.timeoutTasks.removeValue(forKey: callId)
                    resumer.resume(.denied(reason: "Approval timed out after \(Int(timeout))s"))
                }
            }
            timeoutTasks[callId] = timeoutTask
        }

        let channel = resolveChannel.removeValue(forKey: callId) ?? "ui"

        let decisionStr: String
        switch decision {
        case .approved:       decisionStr = "approved"
        case .denied:         decisionStr = "denied"
        case .rememberDeny:   decisionStr = "remembered_deny"
        case .rememberAllow:  decisionStr = "remembered_allow"
        }

        await audit(callId: callId, sessionKey: sessionKey, toolName: toolName,
                    input: input, risk: risk, decision: decisionStr, channel: channel,
                    justification: justification)

        if let relay = telegramRelay {
            Task { await relay.markResolved(callId: callId, decision: decisionStr) }
        }

        if case .rememberDeny = decision {
            await persistPolicy(toolName: toolName, policy: "always_deny")
        }
        if case .rememberAllow = decision {
            await persistPolicy(toolName: toolName, policy: "always_allow")
        }

        // [B6-fix] Map persistent-policy decisions to their effective action so callers
        // that check `== .approved` work correctly (rememberAllow means approved this time too).
        switch decision {
        case .rememberAllow: return .approved
        case .rememberDeny:  return .denied(reason: "Always-deny policy set for \(toolName)")
        default:             return decision
        }
    }

    // MARK: - Resolve from UI

    /// Called by ApprovalCardView or TelegramRelay when user taps Approve/Deny/Remember.
    /// `channel` is "ui" (default) or "telegram" — recorded in the audit log.
    func resolve(callId: String, decision: ApprovalDecision, channel: String = "ui") {
        guard let idx = pendingApprovals.firstIndex(where: { $0.callId == callId }) else { return }
        // [A4-fix] Cancel the timeout watchdog immediately so it doesn't race.
        timeoutTasks.removeValue(forKey: callId)?.cancel()
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
            await reloadPolicies()  // keep published `policies` in sync
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

    // MARK: - Veto toast

    /// Shows a 3-second veto toast for medium-risk actions. Suspends for 3s
    /// then removes the toast. If the user taps Veto before the 3s window,
    /// `vetoResults[callId]` will be set to `.denied`.
    @MainActor
    private func fireMediumRiskVetoToast(
        toolName:      String,
        callId:        String,
        sessionKey:    String,
        input:         [String: Any],
        risk:          ToolRisk,
        justification: String?
    ) async {
        let toast = VetoToast(id: callId, toolName: toolName)
        activeVetoToasts.append(toast)

        // Countdown: tick 3 times then remove. [C8-fix] Use .seconds() not nanoseconds.
        for i in stride(from: 3, through: 1, by: -1) {
            if let idx = activeVetoToasts.firstIndex(where: { $0.id == callId }) {
                activeVetoToasts[idx].secondsLeft = i
            }
            if vetoResults[callId] != nil { break }
            try? await Task.sleep(for: .seconds(1))
        }

        activeVetoToasts.removeAll { $0.id == callId }
    }

    /// Called by the veto toast UI when user taps "Veto".
    func vetoMediumRiskAction(callId: String) {
        vetoResults[callId] = .denied(reason: "User vetoed via 3-second toast")
        activeVetoToasts.removeAll { $0.id == callId }
    }
}
