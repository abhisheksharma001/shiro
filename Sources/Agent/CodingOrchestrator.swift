import Foundation

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

        // Refine prompt via LLM (best-effort; fall back to raw task)
        let refined = await refinePrompt(task: task, workspaceName: ws.name)

        return CodingPlan(
            id:                   UUID().uuidString,
            workspaceName:        ws.name,
            workspacePath:        ws.path,
            branchName:           branch,
            prompt:               refined,
            mode:                 .headless,       // default per BUILD-PLAN decision
            openInIDE:            true,
            allowedTools:         nil,
            maxCostUSD:           defaultMaxCost,
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

        // Note: for headless mode (Phase 4), ClaudeCodeRunner will be used here.
        // For interactive mode (Phase 3 MVP), VS Code opens and user continues there.
        // The .vscode/tasks.json handles launching claude automatically.

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

        // Escape the prompt for JSON — use JSONEncoder to get safe string
        let escapedPrompt: String
        if let data = try? JSONEncoder().encode(prompt),
           let s = String(data: data, encoding: .utf8) {
            // JSONEncoder wraps in quotes — strip them
            escapedPrompt = String(s.dropFirst().dropLast())
        } else {
            escapedPrompt = prompt.replacingOccurrences(of: "\"", with: "\\\"")
        }

        let tasksJSON = """
{
  "version": "2.0.0",
  "tasks": [
    {
      "label": "Shiro: Run Claude Code",
      "type": "shell",
      "command": "claude",
      "args": ["\(escapedPrompt)"],
      "presentation": {
        "echo": true,
        "reveal": "always",
        "focus": true,
        "panel": "new"
      },
      "runOptions": {
        "runOn": "folderOpen"
      },
      "problemMatcher": []
    }
  ]
}
"""
        try tasksJSON.write(to: tasksURL, atomically: true, encoding: .utf8)
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
            // Fallback: open via 'open -a "Visual Studio Code"'
            let (_, err, code) = shell("open", args: ["-a", "Visual Studio Code", path.path])
            if code != 0 {
                throw CodingOrchestratorError.vscodeFailed("VS Code not found. Install it and run: ln -s '/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code' /usr/local/bin/code")
            }
            return
        }
        let (_, err, code) = shell(codePath, args: [path.path])
        if code != 0 {
            throw CodingOrchestratorError.vscodeFailed("code CLI failed: \(err)")
        }
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
        try? p.run()
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
