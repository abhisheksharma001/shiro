import Foundation

// MARK: - MultiCodingPlan (Phase 7)

enum MergeStrategy: String, Codable { case sequentialPRs, singlePR, userReview }

struct Subtask: Codable {
    let title: String
    let prompt: String
    let workspaceName: String
    let branchName: String
    let dependsOn: [String]
    var workspacePath: URL?          // filled in at runtime

    enum CodingKeys: CodingKey {
        case title, prompt, workspaceName, branchName, dependsOn
    }
}

struct MultiCodingPlan: Codable {
    let parentTask: String
    var subtasks: [Subtask]
    let mergeStrategy: MergeStrategy
}

// MARK: - CodingPlan

struct CodingPlan: Codable, Identifiable {
    enum Mode: String, Codable { case interactive, headless, background }

    let id: String                  // UUID string
    let workspaceName: String
    let workspacePath: URL
    let branchName: String          // "shiro/<slug>"
    let prompt: String              // refined for Claude Code
    let mode: Mode
    let openInIDE: Bool
    let allowedTools: [String]?
    var maxCostUSD: Double          // per-task ceiling (default $2.00)
    var estimatedDurationMins: Int?
    var createdAt: Date
}

// MARK: - CodingOrchestrator

@MainActor
final class CodingOrchestrator: ObservableObject {

    @Published var activePlans: [String: CodingPlan] = [:]   // branchName → plan
    @Published var lastError: String?

    weak var appState: AppState?
    var workspaces: WorkspacesRegistry?

    /// Active runner for headless mode — kept so /cancel can kill it.
    private var activeRunner: ClaudeCodeRunner?
    /// Reply token to stream headless output back (Telegram message_id as string).
    var streamReplyToken: String?
    /// Sink to deliver headless streaming events through RemoteInbox.
    weak var remoteSink: RemoteReplySink?

    private let defaultMaxCost: Double = 2.00
    private let encoder = JSONEncoder()

    // MARK: - Plan

    /// Builds a CodingPlan from a task string + optional workspace hint.
    /// Uses LLM to refine the prompt; falls back to raw task on error.
    func plan(task: String, hint: String? = nil) async throws -> CodingPlan {
        // Resolve workspace
        let ws = workspaces?.resolve(hint: hint ?? task)
            ?? workspaces?.workspaces.first

        guard let ws else {
            throw CodingOrchestratorError.noWorkspace(
                "No workspaces found. Run a project scan or specify a path.")
        }

        // Slugify task for branch name
        let slug = task
            .lowercased()
            .components(separatedBy: .alphanumerics.inverted).joined(separator: "-")
            .components(separatedBy: "-").filter { !$0.isEmpty }.prefix(6)
            .joined(separator: "-")
        let branch = "shiro/\(slug)"

        // Load workspace preset (if .shiro/workspace.toml exists)
        let preset = workspaces?.preset(for: ws)

        // Refine prompt via LLM (best-effort; fall back to raw task)
        let refined = await refinePrompt(task: task, workspaceName: ws.name)

        // Determine cost ceiling: preset overrides default
        let costCeiling = preset?.maxCostPerTask ?? defaultMaxCost

        // Determine allowed tools: preset overrides nil (means all)
        let tools = preset?.allowedTools

        // Determine model from preset (stored in plan prompt header or resolved at run time)
        if let model = preset?.defaultModel {
            Config.setActiveModel(model)
        }

        // Apply workspace auto-approve-risk override to ConsentGate.
        // This persists until the plan finishes (runHeadless defer block clears it).
        if let riskStr = preset?.autoApproveRisk,
           let tier = ToolRisk(rawValue: riskStr) {
            appState?.consentGate?.workspaceAutoApproveRisk = tier
            print("[CodingOrchestrator] workspace auto_approve_risk: \(riskStr)")
        }

        return CodingPlan(
            id:                   UUID().uuidString,
            workspaceName:        ws.name,
            workspacePath:        ws.path,
            branchName:           branch,
            prompt:               refined,
            mode:                 .headless,
            openInIDE:            true,
            allowedTools:         tools,
            maxCostUSD:           costCeiling,
            estimatedDurationMins: nil,
            createdAt:            Date()
        )
    }

    // MARK: - Execute

    /// Full orchestration: worktree → tasks.json → VS Code.
    func executePlan(_ plan: CodingPlan) async throws {
        activePlans[plan.branchName] = plan

        // 1. Create git worktree
        let worktreeURL = try createWorktree(workspace: plan.workspacePath,
                                             branch: plan.branchName)

        // 2. Write .vscode/tasks.json so VS Code auto-runs claude on open
        try writeVSCodeTask(at: worktreeURL, prompt: plan.prompt)

        // 3. Open in VS Code (if requested)
        if plan.openInIDE {
            try openInVSCode(at: worktreeURL)
        }

        // 4. For headless mode: spawn ClaudeCodeRunner and stream output.
        //    For interactive mode: VS Code + tasks.json handles it (see above).
        if plan.mode == .headless || plan.mode == .background {
            try await runHeadless(plan: plan, worktreeURL: worktreeURL)
        }

        print("[CodingOrchestrator] plan '\(plan.branchName)' launched — worktree: \(worktreeURL.path)")
    }

    // MARK: - Worktree

    func createWorktree(workspace: URL, branch: String) throws -> URL {
        let worktreesDir = workspace.appendingPathComponent("worktrees")
        let safeBranch   = branch.replacingOccurrences(of: "/", with: "-")
        let worktreeURL  = worktreesDir.appendingPathComponent(safeBranch)

        // Create worktrees directory if needed
        try FileManager.default.createDirectory(at: worktreesDir,
                                                withIntermediateDirectories: true)

        // git worktree add -b <branch> <path>
        // If the branch already exists, try without -b
        let (out1, err1, code1) = shell("git", args: ["-C", workspace.path,
                                                       "worktree", "add", "-b", branch,
                                                       worktreeURL.path])
        if code1 != 0 {
            // Branch may already exist — try without -b
            let (_, err2, code2) = shell("git", args: ["-C", workspace.path,
                                                        "worktree", "add",
                                                        worktreeURL.path, branch])
            if code2 != 0 {
                throw CodingOrchestratorError.worktreeFailed(
                    "git worktree add failed: \(err2.isEmpty ? err1 : err2)")
            }
        }
        _ = out1  // suppress unused

        print("[CodingOrchestrator] worktree created at \(worktreeURL.path)")
        return worktreeURL
    }

    // MARK: - VS Code task injection

    func writeVSCodeTask(at worktreeURL: URL, prompt: String) throws {
        let vscodeDir = worktreeURL.appendingPathComponent(".vscode")
        try FileManager.default.createDirectory(at: vscodeDir, withIntermediateDirectories: true)

        let tasksURL = vscodeDir.appendingPathComponent("tasks.json")

        // [C2-fix] Build tasks.json via JSONSerialization so all special chars (newlines,
        // tabs, backslashes, control chars) are correctly escaped. Manual string interpolation
        // was incomplete and produced invalid JSON for multi-line prompts.
        let task: [String: Any] = [
            "label":   "Shiro: Run Claude Code",
            "type":    "shell",
            "command": "claude",
            "args":    [prompt],
            "presentation": [
                "echo":   true,
                "reveal": "always",
                "focus":  true,
                "panel":  "new"
            ] as [String: Any],
            "runOptions":     ["runOn": "folderOpen"],
            "problemMatcher": [] as [Any]
        ]
        let taskObj: [String: Any] = ["version": "2.0.0", "tasks": [task]]
        let jsonData = try JSONSerialization.data(withJSONObject: taskObj,
                                                  options: [.prettyPrinted, .sortedKeys])
        try jsonData.write(to: tasksURL)
        print("[CodingOrchestrator] .vscode/tasks.json written at \(tasksURL.path)")
    }

    // MARK: - VS Code launch

    func openInVSCode(at path: URL) throws {
        // Find 'code' CLI — standard install locations
        let codePaths = [
            "/usr/local/bin/code",
            "/opt/homebrew/bin/code",
            "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"
        ]
        guard let codePath = codePaths.first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) else {
            // [B1-fix] Verify the app bundle actually exists before using `open -a`.
            let bundlePath = "/Applications/Visual Studio Code.app"
            guard FileManager.default.fileExists(atPath: bundlePath) else {
                throw CodingOrchestratorError.vscodeFailed(
                    "VS Code not found. Install it from https://code.visualstudio.com and run: " +
                    "ln -s '/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code' /usr/local/bin/code")
            }
            let (_, err, code) = shell("open", args: ["-a", "Visual Studio Code", path.path])
            if code != 0 {
                throw CodingOrchestratorError.vscodeFailed("open -a 'Visual Studio Code' failed: \(err)")
            }
            return
        }
        let (_, err, code) = shell(codePath, args: [path.path])
        if code != 0 {
            throw CodingOrchestratorError.vscodeFailed("code CLI failed: \(err)")
        }
    }

    // MARK: - Headless runner

    private func runHeadless(plan: CodingPlan, worktreeURL: URL) async throws {
        // [B7-fix] Always remove the plan from activePlans — even on early throw.
        // Also clear any workspace auto-approve-risk override that was set in buildPlan().
        defer {
            activePlans.removeValue(forKey: plan.branchName)
            appState?.consentGate?.workspaceAutoApproveRisk = nil
        }

        let runner = ClaudeCodeRunner()
        self.activeRunner = runner

        let sink    = remoteSink
        let token   = streamReplyToken
        var textAcc = ""
        var cost    = 0.0

        let stream = await runner.run(
            cwd:          worktreeURL,
            prompt:       plan.prompt,
            allowedTools: plan.allowedTools,
            maxTurns:     50,
            budgetUSD:    plan.maxCostUSD
        )

        for await event in stream {
            switch event {
            case .assistantText(let text):
                textAcc += text
                await sink?.streamChunk(text, replyToken: token)

            case .toolUse(let name, _):   // inputJSON not needed here
                let msg = "\n🔧 `\(name)`"
                textAcc += msg
                await sink?.streamChunk(msg, replyToken: token)

            case .usage(let input, let output, let c) where c > 0:
                cost = c
                // Record spend in CostLedger
                let model = Config.activeModel ?? "claude-sonnet-4-6"
                await appState?.costLedger?.recordUsage(
                    taskId:       plan.branchName,
                    model:        model,
                    inputTokens:  input,
                    outputTokens: output
                )
                if c > plan.maxCostUSD {
                    let errMsg = "\n⚠️ Budget exceeded ($\(String(format: "%.4f", c)) > $\(plan.maxCostUSD))"
                    await sink?.streamError(errMsg, replyToken: token)
                    await runner.cancel()
                    self.activeRunner = nil
                    appState?.logError(source: "CodingOrchestrator", message: errMsg)
                    throw CodingOrchestratorError.headlessFailed(errMsg)
                }

            case .done(let result):
                let summary = "\n\n✅ Done in \(String(format: "%.0f", result.durationSeconds))s"
                    + (cost > 0 ? " · $\(String(format: "%.4f", cost))" : "")
                textAcc += summary
                await sink?.streamFinished(replyToken: token, finalText: textAcc)
                self.activeRunner = nil

            case .error(let msg):
                await sink?.streamError("❌ \(msg)", replyToken: token)
                appState?.logError(source: "ClaudeCodeRunner", message: msg)
                self.activeRunner = nil

            default:
                break
            }
        }
        // activePlans cleanup handled by defer at top of function.
    }

    func cancelHeadless() async {
        await activeRunner?.cancel()
        activeRunner = nil
    }

    // MARK: - Multi-plan (Phase 7)

    /// Decompose a complex task into parallel subtasks.
    func planMulti(task: String, hint: String? = nil) async throws -> MultiCodingPlan {
        guard let appState, let coordinator = appState.agentCoordinator else {
            throw CodingOrchestratorError.noWorkspace("Agent not ready")
        }
        let ws = workspaces?.resolve(hint: hint ?? task) ?? workspaces?.workspaces.first
        guard let ws else { throw CodingOrchestratorError.noWorkspace("No workspace found") }

        let prompt = """
You are a software project planner. Decompose this task into 2-5 independent subtasks \
that can each run in their own git worktree in parallel.

Project: \(ws.name)
Task: \(task)

Rules:
- Each subtask must be independently completable without needing the others to finish first.
- If subtask B depends on A, mark it in dependsOn.
- Branch names must be kebab-case, start with "shiro/".

Output ONLY valid JSON matching this schema:
{
  "parentTask": "<original task>",
  "subtasks": [
    {
      "title": "short title",
      "prompt": "detailed claude code prompt",
      "workspaceName": "\(ws.name)",
      "branchName": "shiro/subtask-slug",
      "dependsOn": []
    }
  ],
  "mergeStrategy": "userReview"
}
"""
        let result = try await coordinator.run(query: prompt)
        guard let start = result.firstIndex(of: "{"),
              let end   = result.lastIndex(of: "}") else {
            throw CodingOrchestratorError.headlessFailed("Could not parse multi-plan JSON")
        }
        let jsonStr = String(result[start...end])
        guard let data = jsonStr.data(using: .utf8) else {
            throw CodingOrchestratorError.headlessFailed("JSON encoding error")
        }
        var plan = try JSONDecoder().decode(MultiCodingPlan.self, from: data)
        // Fill in workspace path for each subtask
        plan.subtasks = plan.subtasks.map { sub in
            var s = sub; s.workspacePath = ws.path; return s
        }
        return plan
    }

    /// Execute a MultiCodingPlan — runs up to 3 subtasks in parallel using TaskGroup.
    /// Pre-resolves workspace paths and creates worktrees on MainActor before launching.
    func executeMulti(_ plan: MultiCodingPlan,
                      sink: RemoteReplySink? = nil,
                      replyToken: String? = nil) async throws {

        await sink?.streamChunk("🚀 Starting \(plan.subtasks.count) subtasks…\n",
                                replyToken: replyToken)

        // Pre-resolve: create all worktrees on MainActor before entering TaskGroup
        struct ResolvedSubtask: Sendable {
            let title: String
            let prompt: String
            let branchName: String
            let worktreeURL: URL
            let dependsOn: [String]
        }

        var resolved: [ResolvedSubtask] = []
        for sub in plan.subtasks {
            let wsPath = workspaces?.workspaces.first(where: { $0.name == sub.workspaceName })?.path
                      ?? workspaces?.workspaces.first?.path
                      ?? sub.workspacePath
            guard let wsPath else {
                await sink?.streamChunk("⚠️ No workspace for subtask '\(sub.title)'\n",
                                        replyToken: replyToken)
                continue
            }
            do {
                let wtURL = try createWorktree(workspace: wsPath, branch: sub.branchName)
                resolved.append(ResolvedSubtask(
                    title:       sub.title,
                    prompt:      sub.prompt,
                    branchName:  sub.branchName,
                    worktreeURL: wtURL,
                    dependsOn:   sub.dependsOn
                ))
            } catch {
                await sink?.streamChunk("⚠️ Worktree failed for '\(sub.title)': \(error.localizedDescription)\n",
                                        replyToken: replyToken)
            }
        }

        // Run in parallel (max 3 at a time), respecting dependsOn DAG
        // Simple approach: topological sort → batch groups → run each batch
        var completedTitles: Set<String> = []
        var remaining = resolved

        while !remaining.isEmpty {
            // Pick subtasks whose dependencies are all satisfied
            let ready = remaining.filter { r in
                r.dependsOn.allSatisfy { completedTitles.contains($0) }
            }
            if ready.isEmpty {
                // Circular dependency or unresolvable — run everything remaining
                break
            }
            remaining.removeAll { r in ready.contains(where: { $0.title == r.title }) }

            // Run this batch (up to 3) in parallel
            let batch = Array(ready.prefix(3))
            var batchResults: [String: Bool] = [:]

            await withTaskGroup(of: (String, Bool).self) { group in
                for sub in batch {
                    let title      = sub.title
                    let prompt     = sub.prompt
                    let wtURL      = sub.worktreeURL
                    let capturedSink = sink
                    let capturedToken = replyToken
                    group.addTask {
                        let runner = ClaudeCodeRunner()
                        var success = true
                        for await event in await runner.run(cwd: wtURL, prompt: prompt, budgetUSD: 2.0) {
                            switch event {
                            case .assistantText(let t):
                                await capturedSink?.streamChunk("[**\(title)**] \(t)\n",
                                                                replyToken: capturedToken)
                            case .done(let r) where r.exitCode != 0:
                                success = false
                            case .error:
                                success = false
                            default: break
                            }
                        }
                        return (title, success)
                    }
                }
                for await (title, success) in group {
                    batchResults[title] = success
                    let icon = success ? "✅" : "❌"
                    await sink?.streamChunk("\(icon) **\(title)** complete\n", replyToken: replyToken)
                }
            }

            for (title, _) in batchResults { completedTitles.insert(title) }
        }

        let succeeded = completedTitles.count
        let total     = resolved.count
        await sink?.streamFinished(replyToken: replyToken,
            finalText: "**Multi-plan complete:** \(succeeded)/\(total) subtasks done.")
    }

    // MARK: - LLM prompt refinement

    private func refinePrompt(task: String, workspaceName: String) async -> String {
        // Best-effort: ask the active bridge to refine the prompt.
        // On failure, return raw task unchanged.
        guard let appState, let coordinator = appState.agentCoordinator else { return task }

        let meta = """
You are a prompt engineer for Claude Code CLI. Given a user's task description, \
rewrite it as a clear, actionable prompt for Claude Code to execute. \
Keep it under 200 words. Be specific. Do not add preamble. Just output the refined prompt.

Project: \(workspaceName)
Task: \(task)
"""
        do {
            let result = try await coordinator.run(query: meta)
            let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? task : trimmed
        } catch {
            print("[CodingOrchestrator] prompt refinement failed: \(error.localizedDescription) — using raw task")
            return task
        }
    }

    // MARK: - Shell helper

    @discardableResult
    private func shell(_ cmd: String, args: [String]) -> (stdout: String, stderr: String, code: Int32) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = [cmd] + args
        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError  = errPipe
        // [C7-fix] Propagate launch errors instead of silently returning code 0.
        do {
            try p.run()
        } catch {
            let msg = "Failed to launch \(cmd): \(error.localizedDescription)"
            print("[CodingOrchestrator] shell error: \(msg)")
            return ("", msg, -1)
        }
        p.waitUntilExit()
        let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (out, err, p.terminationStatus)
    }
}

// MARK: - Errors

enum CodingOrchestratorError: LocalizedError {
    case noWorkspace(String)
    case worktreeFailed(String)
    case vscodeFailed(String)
    case headlessFailed(String)

    var errorDescription: String? {
        switch self {
        case .noWorkspace(let s):   return "No workspace: \(s)"
        case .worktreeFailed(let s): return "Worktree error: \(s)"
        case .vscodeFailed(let s):  return "VS Code error: \(s)"
        case .headlessFailed(let s): return "Headless error: \(s)"
        }
    }
}
