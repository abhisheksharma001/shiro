import Foundation
import GRDB

// MARK: - SubAgentManager
//
// Owns the sub-agent registry. Responsibilities:
//   1. Atomic task checkout — prevents two agents grabbing the same task
//      via: UPDATE tasks SET status='in_progress', assigned_agent=?
//             WHERE id=? AND status='todo' RETURNING *
//   2. Session registration — records every bridge sessionKey → AgentSession row
//   3. Depth guard — refuses spawn if parent is already at depthBudget
//   4. Cost guard — stops agents that exceed their costBudgetUsd
//   5. Lifecycle tracking — transitions agent_sessions rows as bridge events arrive

actor SubAgentManager {

    // MARK: - Configuration

    static let defaultDepthBudget: Int    = 3      // max nesting levels
    static let defaultCostBudgetUsd: Double = 0.50 // per sub-agent, ~500k tokens

    // MARK: - Live session map  (sessionKey → running info)

    struct RunningSession {
        let sessionKey: String
        let taskId: String?
        let parentKey: String?
        let depth: Int
        let costBudgetUsd: Double?
        var costAccrued: Double = 0.0
        let depthBudget: Int
    }

    var activeSessions: [String: RunningSession] = [:]
    var completedCount: Int = 0
    var failedCount: Int    = 0

    private let db: ShiroDatabase

    init(database: ShiroDatabase) {
        self.db = database
    }

    // MARK: - Atomic task checkout

    /// Attempt to claim a todo task for the given agent. Returns the task on
    /// success, nil if already taken (race) or not found.
    func checkoutTask(id taskId: String, agent: String) async -> ShiroTask? {
        do {
            return try await db.pool.write { conn -> ShiroTask? in
                // SQLite does not support RETURNING in older versions; use a
                // check-then-update within a single write transaction instead.
                let task = try ShiroTask.filter(
                    Column("id")     == taskId &&
                    Column("status") == "todo"
                ).fetchOne(conn)

                guard var t = task else { return nil }
                t.status        = "in_progress"
                t.assignedAgent = agent
                t.startedAt     = Date()
                t.updatedAt     = Date()
                try t.update(conn)
                return t
            }
        } catch {
            print("[SubAgentManager] checkoutTask error: \(error)")
            return nil
        }
    }

    // MARK: - Session registration

    /// Called when a spawn_agent message is about to be sent to the bridge.
    /// Validates depth + cost budget, creates AgentSession row, registers in memory map.
    /// Returns an error string if the spawn should be blocked.
    func registerSession(
        sessionKey:    String,
        taskId:        String?,
        parentKey:     String?,
        persona:       String?,
        model:         String?,
        costBudgetUsd: Double?,
        depthBudget:   Int?
    ) async -> String? {          // nil = ok; non-nil = error message

        // Depth guard
        let parentDepth = parentKey.flatMap { activeSessions[$0] }?.depth ?? 0
        let myDepth     = parentDepth + 1
        let budget      = depthBudget ?? Self.defaultDepthBudget
        if myDepth > budget {
            return "Depth limit (\(budget)) reached — cannot spawn deeper sub-agent."
        }

        // Register in memory
        let session = RunningSession(
            sessionKey:    sessionKey,
            taskId:        taskId,
            parentKey:     parentKey,
            depth:         myDepth,
            costBudgetUsd: costBudgetUsd ?? Self.defaultCostBudgetUsd,
            depthBudget:   budget
        )
        activeSessions[sessionKey] = session

        // Persist to DB
        let row = AgentSession.new(
            id:            sessionKey,
            taskId:        taskId,
            parentSessionId: parentKey,
            depth:         myDepth,
            persona:       persona,
            model:         model,
            costBudgetUsd: costBudgetUsd ?? Self.defaultCostBudgetUsd,
            depthBudget:   budget
        )
        do {
            try await db.pool.write { conn in
                try row.insert(conn, onConflict: .replace)
            }
        } catch {
            print("[SubAgentManager] persist session error: \(error)")
        }

        return nil
    }

    // MARK: - Cost accrual + budget enforcement

    /// Returns true if the session should be killed (budget exceeded).
    func recordCost(sessionKey: String, costUsd: Double) async -> Bool {
        guard var session = activeSessions[sessionKey] else { return false }
        session.costAccrued += costUsd
        activeSessions[sessionKey] = session

        guard let budget = session.costBudgetUsd else { return false }
        let exceeded = session.costAccrued >= budget

        // Immutable snapshot to cross the Sendable closure boundary.
        let snapshot = session
        let key = sessionKey

        // Update DB cost column regardless.
        do {
            try await db.pool.write { conn in
                try conn.execute(
                    sql: "UPDATE agent_sessions SET cost_usd = ? WHERE id = ?",
                    arguments: [snapshot.costAccrued, key]
                )
                if exceeded {
                    try conn.execute(
                        sql: "UPDATE agent_sessions SET status = 'budget_exceeded', completed_at = CURRENT_TIMESTAMP WHERE id = ?",
                        arguments: [key]
                    )
                }
            }
        } catch {
            print("[SubAgentManager] recordCost DB error: \(error.localizedDescription)")
        }

        if exceeded {
            print("[SubAgentManager] ⚠️  Session '\(key)' exceeded budget \(budget) USD (accrued \(snapshot.costAccrued))")
        }
        return exceeded
    }

    // MARK: - Session lifecycle

    func markCompleted(sessionKey: String, result: String?, totalCostUsd: Double) async {
        activeSessions.removeValue(forKey: sessionKey)
        completedCount += 1

        do {
            try await db.pool.write { conn in
                try conn.execute(
                    sql: """
                    UPDATE agent_sessions
                    SET status = 'completed', result = ?, cost_usd = ?, completed_at = CURRENT_TIMESTAMP
                    WHERE id = ?
                    """,
                    arguments: [result, totalCostUsd, sessionKey]
                )
            }
        } catch {
            print("[SubAgentManager] markCompleted error: \(error)")
        }
    }

    func markFailed(sessionKey: String, error errorMsg: String) async {
        activeSessions.removeValue(forKey: sessionKey)
        failedCount += 1

        do {
            try await db.pool.write { conn in
                try conn.execute(
                    sql: """
                    UPDATE agent_sessions
                    SET status = 'failed', error = ?, completed_at = CURRENT_TIMESTAMP
                    WHERE id = ?
                    """,
                    arguments: [errorMsg, sessionKey]
                )
            }
        } catch {
            print("[SubAgentManager] markFailed error: \(error)")
        }
    }

    // MARK: - Queue processing

    /// Pick the highest-priority pending task from the queue and check it out
    /// for the given agent. Returns nil when queue is empty.
    func dequeueNextTask(agent: String) async -> ShiroTask? {
        do {
            return try await db.pool.write { conn -> ShiroTask? in
                let task = try ShiroTask
                    .filter(Column("status") == "todo")
                    .order(
                        // urgent=0, high=1, medium=2, low=3 for ordering
                        SQL("""
                        CASE priority
                          WHEN 'urgent' THEN 0
                          WHEN 'high'   THEN 1
                          WHEN 'medium' THEN 2
                          ELSE 3
                        END
                        """),
                        Column("created_at").asc
                    )
                    .fetchOne(conn)

                guard var t = task else { return nil }
                t.status        = "in_progress"
                t.assignedAgent = agent
                t.startedAt     = Date()
                t.updatedAt     = Date()
                try t.update(conn)
                return t
            }
        } catch {
            print("[SubAgentManager] dequeue error: \(error)")
            return nil
        }
    }

    // MARK: - Reads

    func activeSessionCount() -> Int { activeSessions.count }

    func depth(ofSession key: String) -> Int {
        activeSessions[key]?.depth ?? 0
    }

    func pendingTaskCount() async -> Int {
        (try? await db.pool.read { conn in
            try ShiroTask.filter(Column("status") == "todo").fetchCount(conn)
        }) ?? 0
    }
}
