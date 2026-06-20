import Foundation
import GRDB

// MARK: - ModelPricing

enum ModelPricing {
    /// Returns cost in USD for the given token counts.
    static func compute(model: String, inputTokens: Int, outputTokens: Int) -> Double {
        let m = model.lowercased()
        let (inputRate, outputRate): (Double, Double)
        if m.contains("opus") {
            inputRate  = 5.0 / 1_000_000
            outputRate = 25.0 / 1_000_000
        } else if m.contains("haiku") {
            inputRate  = 1.0 / 1_000_000
            outputRate = 5.0 / 1_000_000
        } else {
            // Default / sonnet
            inputRate  = 3.0 / 1_000_000
            outputRate = 15.0 / 1_000_000
        }
        return Double(inputTokens) * inputRate + Double(outputTokens) * outputRate
    }
}

// MARK: - CostLedger

@MainActor
final class CostLedger: ObservableObject {

    @Published var todaySpend:   Double = 0
    @Published var monthSpend:   Double = 0
    /// Recent tasks sorted by cost desc — for the Budget tab table.
    @Published var topTasks:     [TaskCostSummary] = []

    private let db: ShiroDatabase

    struct TaskCostSummary: Identifiable {
        let id:       String   // taskId
        let taskId:   String
        let totalCost: Double
        let model:    String
        let recordedAt: Date
    }

    init(database: ShiroDatabase) {
        self.db = database
        Task { await refresh() }
    }

    // MARK: - Record

    func recordUsage(
        taskId:       String,
        sessionId:    String? = nil,
        model:        String,
        inputTokens:  Int,
        outputTokens: Int
    ) async {
        let cost = ModelPricing.compute(model: model,
                                        inputTokens: inputTokens,
                                        outputTokens: outputTokens)
        let record = CostRecord(
            id:           UUID().uuidString,
            taskId:       taskId,
            sessionId:    sessionId,
            model:        model,
            inputTokens:  inputTokens,
            outputTokens: outputTokens,
            costUSD:      cost,
            createdAt:    Date()
        )
        do {
            try await db.pool.write { conn in try record.insert(conn) }
        } catch {
            print("[CostLedger] insert error: \(error)")
        }
        // Update aggregates
        todaySpend += cost
        monthSpend += cost
        // Refresh top-tasks (deferred to avoid per-token DB reads)
        Task { await self.refreshTopTasks() }
    }

    // MARK: - Query

    func taskSpend(_ taskId: String) async -> Double {
        (try? await db.pool.read { conn in
            try Double.fetchOne(conn, sql:
                "SELECT COALESCE(SUM(cost_usd),0) FROM cost_records WHERE task_id = ?",
                arguments: [taskId])
        }) ?? 0
    }

    // MARK: - Refresh

    func refresh() async {
        await refreshAggregates()
        await refreshTopTasks()
    }

    private func refreshAggregates() async {
        // [A5-fix] Pass Date values directly to GRDB — it serialises them as ISO8601 UTC
        // internally, matching what it stores for `created_at` columns. This is more reliable
        // than manually constructing ISO8601 strings which can have timezone mismatches.
        let todayStart = Calendar.current.startOfDay(for: Date())
        todaySpend = (try? await db.pool.read { conn in
            try Double.fetchOne(conn, sql:
                "SELECT COALESCE(SUM(cost_usd),0) FROM cost_records WHERE created_at >= ?",
                arguments: [todayStart])
        }) ?? 0

        // This month
        let cal   = Calendar.current
        let comps = cal.dateComponents([.year, .month], from: Date())
        if let monthStart = cal.date(from: comps) {
            monthSpend = (try? await db.pool.read { conn in
                try Double.fetchOne(conn, sql:
                    "SELECT COALESCE(SUM(cost_usd),0) FROM cost_records WHERE created_at >= ?",
                    arguments: [monthStart])
            }) ?? 0
        }
    }

    private func refreshTopTasks() async {
        struct Row: FetchableRecord {
            let taskId: String
            let total:  Double
            let model:  String
            let latest: Date
            init(row: GRDB.Row) {
                taskId = row["task_id"]
                total  = row["total"]
                model  = row["model"]
                latest = row["latest"]
            }
        }
        let rows = (try? await db.pool.read { conn in
            try Row.fetchAll(conn, sql: """
                SELECT task_id, SUM(cost_usd) as total, model,
                       MAX(created_at) as latest
                FROM cost_records
                GROUP BY task_id
                ORDER BY total DESC
                LIMIT 10
            """)
        }) ?? []
        topTasks = rows.map { TaskCostSummary(
            id:         $0.taskId,
            taskId:     $0.taskId,
            totalCost:  $0.total,
            model:      $0.model,
            recordedAt: $0.latest
        )}
    }

    // MARK: - Default per-task ceiling

    static let defaultTaskCeiling: Double = 2.00   // $2.00
    private static let ceilingKey = "shiro.taskCostCeiling"

    var taskCostCeiling: Double {
        get { UserDefaults.standard.double(forKey: Self.ceilingKey) > 0
            ? UserDefaults.standard.double(forKey: Self.ceilingKey)
            : Self.defaultTaskCeiling }
        set { UserDefaults.standard.set(newValue, forKey: Self.ceilingKey) }
    }
}
