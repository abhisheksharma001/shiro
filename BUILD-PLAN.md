# BUILD-PLAN.md — Sonnet Execution Plan
**Created:** 2026-05-01 (by Opus 4.6, executed by Sonnet 4.6)
**Goal:** Implement Shiro Mobile + Coding Orchestrator end-to-end.
**Reference docs:** `PLAN-2026-05-01.md` (strategy), `HANDOFF.md` (last session state).

---

## ⚙️ LOCKED-IN DECISIONS (do not re-litigate)

| Decision | Value |
|---|---|
| Coding terminal | **VS Code integrated terminal** (not iTerm, not Terminal.app) |
| Launch mechanism | `.vscode/tasks.json` with `runOn: folderOpen` runs `claude` automatically |
| Project sources | Local `~/Projects/*` (auto-scan) + GitHub repos (via MCP + `gh` CLI) |
| GitHub agent layer | GitHub MCP server (already in user's setup, see CLAUDE.md) |
| GitHub orchestration | `gh` CLI shelled out from Swift (clone, list, create PR) |
| Mobile transport | Telegram bot API (already wired for approvals) |
| Default `/code` mode | `headless` (since target is phone — interactive needs human at Mac) |
| Cost ceiling | $2.00 default per `/code` invocation; user-configurable in Settings |
| Sub-agent system | Both runtime spawn (parallel claude processes) + definition synthesis (auto-write `.claude/agents/*.md`) |
| Auth for HTTP/Shortcuts | Bearer token in keychain `shiro_remote_token`; bind to localhost + Tailscale IP only |

---

## 📜 INSTRUCTIONS FOR SONNET (read this first, every session)

1. **Read these files in full before any code change:**
   - `HANDOFF.md` — what was just done
   - `Sources/App/AppState.swift` — central state (1000+ lines)
   - `Sources/Bridge/BridgeRouter.swift` — message routing
   - The specific files mentioned in the current phase

2. **Workflow per phase:**
   - Read all referenced files completely (no skimming)
   - Implement step-by-step in the order written
   - After each step: `cd ~/Projects/shiro && swift build` — must succeed with 0 errors
   - After each phase: kill old process, relaunch, manual smoke test
   - After each phase: update `HANDOFF.md`
   - Commit per phase with conventional commit message

3. **Build/run/kill (memorize):**
   ```bash
   cd ~/Projects/shiro && swift build       # build (5-30s)
   .build/debug/Shiro                        # run (foreground)
   pkill -f "\.build/debug/Shiro"            # kill
   cd ~/Projects/shiro/acp-bridge && npm run build  # bridge build (if changed)
   ```

4. **DO NOT:**
   - Refactor unrelated code
   - Add new dependencies without justifying in HANDOFF.md
   - Skip verification ("should work" is banned per CLAUDE.md)
   - Use placeholder comments like `// TODO: implement`
   - Truncate code with `// ... rest unchanged`

5. **DO:**
   - Run the app and click through the new feature
   - Add a print statement for each new code path during initial dev (remove before commit)
   - Use `appState.logError(source:message:)` for any error — never silent fail
   - Reference exact file paths + line numbers in HANDOFF.md

---

## 🗺️ PHASE OVERVIEW

| Phase | Title | Hours | Dependencies |
|---|---|---|---|
| 0 | Tool Policies UI + Audit Viewer | 4 | none |
| 1 | Telegram Bidirectional Chat | 4 | 0 |
| 2 | RemoteInbox Abstraction | 3 | 1 |
| 3 | CodingOrchestrator + `/code` MVP | 6 | 0 |
| 4 | Headless Mode + Streaming | 6 | 3 |
| 5 | GitHub Integration | 4 | 3 |
| 6 | HTTP Server + iOS Shortcuts | 4 | 2 |
| 7 | Parent/Sub-Agent System | 6 | 4 |
| 8 | Cost Ceiling + Budget Tracking | 3 | 4 |
| 9 | Polish (⌘K, voice, presets) | 6 | all |

**Total:** ~46h focused work. Run as 1 phase per session to keep context clean.

---

## PHASE 0 — Tool Policies UI + Audit Viewer
**Goal:** Close the loop on yesterday's "Always Allow" feature. User must be able to see/revoke policies and review past approvals.

### Files
- **EDIT** `Sources/UI/FloatingBar/FloatingBarView.swift` — add 2 new tabs to Settings
- **EDIT** `Sources/Agent/ConsentGate.swift` — expose `policyCache` snapshot + `revokePolicy(toolName:)`
- **NEW** none

### Steps

**0.1 — Expose policies from ConsentGate**
Add to `ConsentGate`:
```swift
struct PolicyEntry: Identifiable {
    var id: String { toolName }
    let toolName: String
    let policy: String        // "always_allow" | "always_deny"
    let updatedAt: Date
}

@Published private(set) var policies: [PolicyEntry] = []

func reloadPolicies() async { /* re-query DB, populate published array */ }
func revokePolicy(toolName: String) async { /* DELETE from tool_policies + cache */ }
func setPolicyManual(toolName: String, policy: String) async { /* same as persistPolicy but public */ }
```
Call `reloadPolicies()` in init after `loadPolicies()`. Call after every `persistPolicy()` write.

**0.2 — `PoliciesTab` view**
In `FloatingBarView.swift`, add `private struct PoliciesTab: View` next to existing `ErrorLogTab`:
- List of `consentGate.policies` sorted by `updatedAt` desc
- Each row: tool name (mono font), policy badge (green=allow, red=deny), updatedAt timestamp, trash icon
- Trash icon → calls `consentGate.revokePolicy(toolName:)`
- Empty state: "No saved policies. Use 'Always Allow' or 'Never Allow' on approval cards to create one."

**0.3 — `AuditTab` view**
Reads `ToolApproval` rows via `consentGate.recentApprovals(limit: 100)`:
- Table-like list: timestamp, tool name, decision badge (color-coded), channel (ui/telegram/auto)
- Filter pills at top: All / Approved / Denied / Auto
- Search box — filter by toolName
- "Revert this approval" button on rows where decision was approved → flips policy to `always_deny`
- Refresh button at top

**0.4 — Wire into Settings**
In `SettingsView` TabView, add tabs (height 560 → 600 if needed):
- tag 6: PoliciesTab
- tag 7: AuditTab

### Verification
```bash
swift build && .build/debug/Shiro &
# Manual: Open Settings → Policies tab → see policies from yesterday's "Always Allow" testing
# Click trash → policy disappears, next approval card prompts again
# Open Audit tab → see all approval history
```

### Commit
`feat: tool policies tab + audit log viewer in settings`

---

## PHASE 1 — Telegram Bidirectional Chat
**Goal:** Send a free-text message in Telegram → Shiro processes it as a prompt → reply streams back.

### Files
- **EDIT** `Sources/Bridge/TelegramRelay.swift` — extend `handleUpdate` for `message.text`
- **EDIT** `Sources/App/AppState.swift` — expose `runPromptHeadless(prompt:) -> AsyncStream<String>` if not present (check first)
- **EDIT** `Sources/Bridge/BridgeRouter.swift` — add hook for "external" prompt sources

### Steps

**1.1 — Inspect existing surface**
Read `BridgeRouter.swift` and `AppState.swift` fully. Find the function that takes a prompt string and runs it. If it's tightly coupled to UI (FloatingBar's send), extract a public method:
```swift
// AppState.swift
func runRemotePrompt(_ text: String, source: String) async -> AsyncStream<String> {
    // wraps existing send pipeline; source is logged in audit
}
```

**1.2 — Telegram message handler**
In `TelegramRelay.handleUpdate`, before the existing callback_query branch, add:
```swift
if let message = update["message"] as? [String: Any],
   let chat = message["chat"] as? [String: Any],
   let chatIdInt = chat["id"] as? Int,
   String(chatIdInt) == self.chatId,
   let text = message["text"] as? String {
    await handleIncomingText(text)
    return
}
```

`handleIncomingText`:
- If text starts with `/`, treat as command (`/start`, `/cancel`, `/model <name>`, `/status`, `/code <task>`)
- Otherwise: `await notify("⏳ Working...")`, then call `appState.runRemotePrompt(text, source: "telegram")`, stream chunks back via `editMessage` (every ~500ms or 80 chars, whichever first)
- On completion: edit message with final text + cost summary

**1.3 — Slash commands**
Implement: `/start` (welcome), `/cancel` (stop running task), `/model sonnet|opus|haiku` (switch active model), `/status` (current model + last cost), `/code <task>` (placeholder until Phase 3)

**1.4 — Throttled message editing**
Telegram has a 30 msg/sec rate limit. Buffer streaming output:
```swift
actor StreamBuffer {
    private var pending = ""
    private var lastFlush = Date.distantPast
    func append(_ s: String, flush: () async -> Void) async { /* buffer; if >500ms or >80 chars, flush */ }
}
```

### Verification
```bash
# Send "what time is it" to your bot from phone
# Expected: ⏳ Working... → replaced with answer within 5s
# Send "/model haiku" → confirmation
# Send "/status" → shows "haiku, last cost $0.00"
```

### Commit
`feat: telegram bidirectional chat with streaming replies`

---

## PHASE 2 — RemoteInbox Abstraction
**Goal:** Decouple TelegramRelay from message routing. Future transports (HTTP, PWA) plug in without touching Telegram code.

### Files
- **NEW** `Sources/Bridge/RemoteInbox.swift`
- **EDIT** `Sources/Bridge/TelegramRelay.swift` — emit to RemoteInbox instead of calling AppState directly
- **EDIT** `Sources/App/AppState.swift` — wire RemoteInbox at startup

### Steps

**2.1 — Define types**
```swift
// RemoteInbox.swift
enum RemoteChannel: String { case telegram, http, pwa }

struct RemoteMessage: Identifiable {
    let id: String           // dedupe key
    let channel: RemoteChannel
    let senderId: String     // chat_id, ip, etc.
    let text: String
    let timestamp: Date
    let replyToken: String?  // opaque; transport-specific (telegram message_id, http callback)
}

protocol RemoteReplySink: Actor {
    func reply(to: String, text: String, isFinal: Bool) async
    func error(to: String, message: String) async
}

@MainActor
final class RemoteInbox: ObservableObject {
    @Published var recent: [RemoteMessage] = []  // for debugging UI
    private var sinks: [RemoteChannel: RemoteReplySink] = [:]
    func register(_ sink: RemoteReplySink, for channel: RemoteChannel) { ... }
    func receive(_ msg: RemoteMessage) async { /* dedupe → route to AppState → reply via sink */ }
}
```

**2.2 — Telegram conforms**
Make `TelegramRelay` conform to `RemoteReplySink`. Move text-handling from Phase 1 into a callback that emits `RemoteMessage` to `RemoteInbox`.

**2.3 — Wire at startup**
In `AppState.initialize()` or `ShiroApp`:
```swift
let inbox = RemoteInbox()
if let relay = telegramRelay { inbox.register(relay, for: .telegram) }
self.remoteInbox = inbox
```

### Verification
- Same Phase 1 test still works (regression check)
- `appState.remoteInbox.recent` populates with messages (visible in future debug tab)

### Commit
`refactor: extract RemoteInbox transport abstraction`

---

## PHASE 3 — CodingOrchestrator + `/code` MVP
**Goal:** Slash command `/code <task>` from floating bar → opens VS Code at a worktree → VS Code's integrated terminal auto-runs `claude "<task>"`.

### Files
- **NEW** `Sources/Agent/CodingOrchestrator.swift`
- **NEW** `Sources/Agent/Workspaces.swift` (project registry)
- **EDIT** `Sources/Agent/SkillsRegistry.swift` — register `code_with_claude` skill
- **EDIT** `Sources/UI/FloatingBar/FloatingBarView.swift` — slash command parser (find existing one)
- **EDIT** `Sources/UI/MainWindow/ShiroMainWindowView.swift` — same

### Steps

**3.1 — Workspaces registry**
```swift
// Workspaces.swift
struct Workspace: Codable, Identifiable {
    var id: String { path.path }  // URL.path
    let name: String              // dir basename
    let path: URL
    let isGitRepo: Bool
    let lastSeenAt: Date
    let remoteOriginUrl: String?
}

@MainActor
final class WorkspacesRegistry: ObservableObject {
    @Published private(set) var workspaces: [Workspace] = []

    /// Scans ~/Projects (configurable) for git repos.
    func scan(roots: [URL] = [URL.homeDirectory.appending(path: "Projects")]) async { ... }

    /// Fuzzy-matches user-input string to a workspace.
    func resolve(hint: String) -> Workspace? { ... }   // "the shiro repo" → Shiro

    /// Persists to ~/.shiro/workspaces.json
    func save() throws { ... }
    func load() throws { ... }
}
```

Auto-scan on app launch. Show count in main window: "12 projects indexed".

**3.2 — CodingPlan + Orchestrator**
```swift
// CodingOrchestrator.swift
struct CodingPlan: Codable {
    enum Mode: String, Codable { case interactive, headless, background }
    let workspaceId: String
    let branchName: String
    let prompt: String
    let mode: Mode
    let openInIDE: Bool
    let allowedTools: [String]?
    let maxCostUSD: Double  // see Phase 8
    let estimatedDurationMins: Int?
}

@MainActor
final class CodingOrchestrator: ObservableObject {
    @Published var activePlans: [String: CodingPlan] = [:]   // by branchName

    func plan(task: String, hint: String?) async throws -> CodingPlan {
        // LLM call: takes task → produces structured plan
        // Use AppState's existing model client
    }

    func createWorktree(_ workspace: Workspace, branch: String) throws -> URL {
        // Run: git worktree add -b <branch> ./worktrees/<branch>
        // Return worktree URL
    }

    func writeVSCodeTask(at: URL, prompt: String) throws {
        // Writes .vscode/tasks.json with runOn: folderOpen task
        // See template below
    }

    func openInVSCode(at: URL) throws {
        // Run: code <path>
        // VS Code prompts user once to allow auto-run; remembers per-workspace
    }

    func executePlan(_ plan: CodingPlan) async throws { /* ties it all together */ }
}
```

**3.3 — `.vscode/tasks.json` template**
```json
{
  "version": "2.0.0",
  "tasks": [
    {
      "label": "Shiro: Run Claude Code",
      "type": "shell",
      "command": "claude",
      "args": ["<PROMPT_PLACEHOLDER>"],
      "presentation": { "echo": true, "reveal": "always", "focus": true, "panel": "new" },
      "runOptions": { "runOn": "folderOpen" },
      "problemMatcher": []
    }
  ]
}
```
Substitute `<PROMPT_PLACEHOLDER>` with the actual prompt (escape quotes properly — use JSONEncoder, not string concat).

VS Code on first folder-open with a `runOn: folderOpen` task asks user "Allow automatic tasks in folder?" — they click Allow once per workspace, then it runs every open.

**3.4 — Slash command parser**
Find existing slash-command handler in FloatingBarView (search for `"/"` or `slashCommand`). Add:
```swift
case "/code":
    let task = arguments.trimmingCharacters(in: .whitespaces)
    guard !task.isEmpty else { showError("Usage: /code <task description>"); return }
    Task {
        do {
            let plan = try await orchestrator.plan(task: task, hint: nil)
            // Show plan preview in approval card; on approve → executePlan
            try await orchestrator.executePlan(plan)
        } catch {
            appState.logError(source: "CodingOrchestrator", message: error.localizedDescription)
        }
    }
```

**3.5 — Skill registration**
In `SkillsRegistry`, add `code_with_claude` skill so it's discoverable by the LLM (in addition to slash command).

### Verification
```bash
# In floating bar: /code add a hello.txt with "hi" in this repo
# Expected:
# 1. Plan preview appears (target project, branch name, prompt, mode)
# 2. On approve: VS Code window opens at ~/Projects/shiro/worktrees/shiro-hello-txt
# 3. VS Code prompts to allow auto-run task → click Allow
# 4. Integrated terminal opens, runs: claude "add a hello.txt with 'hi' in this repo"
# 5. Claude Code does its thing
```

### Commit
`feat: /code slash command launches Claude Code in VS Code worktree`

---

## PHASE 4 — Headless Mode + Streaming
**Goal:** `/code` from Telegram works in headless mode; output streams back to phone.

### Files
- **EDIT** `Sources/Agent/CodingOrchestrator.swift` — add headless path
- **NEW** `Sources/Agent/ClaudeCodeRunner.swift` — Process wrapper for `claude -p`
- **EDIT** `Sources/Bridge/TelegramRelay.swift` — handle `/code` command (was placeholder)

### Steps

**4.1 — ClaudeCodeRunner**
```swift
actor ClaudeCodeRunner {
    struct RunResult {
        let exitCode: Int32
        let totalCostUSD: Double
        let durationSeconds: TimeInterval
        let sessionId: String?
    }

    /// Spawns: claude -p "<prompt>" --output-format stream-json --max-turns 50 --allowedTools <list>
    /// Streams parsed JSONL events as AsyncStream<ClaudeEvent>.
    func run(
        cwd: URL,
        prompt: String,
        allowedTools: [String]?,
        maxTurns: Int = 50,
        budgetUSD: Double
    ) -> AsyncStream<ClaudeEvent>
}

enum ClaudeEvent {
    case assistantText(String)
    case toolUse(name: String, input: [String: Any])
    case toolResult(name: String, output: String, isError: Bool)
    case usage(inputTokens: Int, outputTokens: Int, costUSD: Double)
    case sessionId(String)
    case done(RunResult)
    case error(String)
}
```

JSONL format from `claude -p --output-format stream-json` — each line is a JSON object with `type` field. Parse and map.

**4.2 — Headless executePlan path**
In `CodingOrchestrator.executePlan`, when `plan.mode == .headless`:
```swift
let runner = ClaudeCodeRunner()
for await event in runner.run(cwd: worktreeURL, prompt: plan.prompt, ...) {
    switch event {
    case .assistantText(let s): await replySink?.reply(to: replyToken, text: s, isFinal: false)
    case .toolUse(let name, _): await replySink?.reply(to: replyToken, text: "🔧 \(name)", isFinal: false)
    case .usage(_, _, let cost):
        if cost > plan.maxCostUSD {
            // kill process, notify user
        }
    case .done(let result): await replySink?.reply(to: replyToken, text: "✅ done in \(result.durationSeconds)s, $\(result.totalCostUSD)", isFinal: true)
    case .error(let msg): appState.logError(source: "ClaudeCode", message: msg)
    }
}
```

**4.3 — Telegram `/code` integration**
When user sends `/code <task>` from Telegram:
- Build plan with `mode: .headless`
- Skip approval card (headless = no human in loop) OR send approval card via Telegram (preferred — security)
- Stream output back via the throttled buffer from Phase 1

**4.4 — Cancellation**
`/cancel` from Telegram → kill the active `claude` Process (SIGTERM, then SIGKILL after 3s).

### Verification
```bash
# From phone, send: /code create a TIMELINE.md in ~/Projects/test-repo with today's date
# Expected:
# - Plan preview message
# - Approve via Telegram button
# - Streaming "🔧 Read", "🔧 Write", final "✅ done in 12s, $0.04"
# - File actually exists on Mac afterward
```

### Commit
`feat: headless claude code orchestration with telegram streaming`

---

## PHASE 5 — GitHub Integration
**Goal:** `/code` can target a GitHub repo (clone if missing). User can `/repos` to list, `/clone <name>` to fetch.

### Files
- **NEW** `Sources/Agent/GitHubBridge.swift` — wraps `gh` CLI
- **EDIT** `Sources/Agent/Workspaces.swift` — add `cloneFromGitHub(repo:)` 
- **EDIT** `Sources/Agent/CodingOrchestrator.swift` — resolveProject can fall through to GitHub
- **EDIT** `Sources/Bridge/TelegramRelay.swift` — `/repos`, `/clone` commands

### Steps

**5.1 — GitHubBridge (CLI wrapper)**
```swift
actor GitHubBridge {
    /// Calls: gh repo list --limit 100 --json name,description,url,updatedAt
    func listRepos() async throws -> [GHRepo]

    /// Calls: gh repo view <owner/name> --json ...
    func viewRepo(_ slug: String) async throws -> GHRepoDetail

    /// Calls: gh repo clone <slug> <dest>
    func clone(slug: String, to dest: URL) async throws

    /// Calls: gh pr create --base <base> --head <head> --title <t> --body <b>
    func createPR(repo: URL, base: String, head: String, title: String, body: String) async throws -> URL

    /// Checks if `gh` is installed and authed.
    func checkAuth() async throws -> String   // returns gh username
}
```

Use `Process` to shell out. Parse JSON output (`gh` supports `--json`).

**5.2 — Workspaces extension**
```swift
extension WorkspacesRegistry {
    func cloneFromGitHub(_ slug: String) async throws -> Workspace {
        let dest = URL.homeDirectory.appending(path: "Projects/\(slug.split(separator: "/").last!)")
        try await GitHubBridge().clone(slug: slug, to: dest)
        await scan()  // refresh registry
        return resolve(hint: dest.lastPathComponent)!
    }
}
```

**5.3 — MCP layer note**
GitHub MCP server is already configured globally (per `~/.claude/CLAUDE.md` setup). Claude Code subagents launched by Shiro can use it directly for repo searches, issue reading, etc. — **no Shiro-side code needed for that path.**

When Shiro itself needs GitHub (listing user's repos for `/repos` command, cloning, creating PRs), use `GitHubBridge` (the `gh` CLI wrapper). Two clean layers:
- LLM-side intelligence → MCP (handled by Claude Code)
- Swift-side orchestration → `gh` CLI

**5.4 — Telegram commands**
- `/repos` → calls `GitHubBridge.listRepos`, replies with paginated list (Telegram inline keyboard for paging)
- `/clone <owner/repo>` → calls `cloneFromGitHub`, confirms when done
- `/code-pr <task>` → after `/code` completes, auto-creates PR

### Verification
```bash
# /repos → list of your GitHub repos
# /clone abhishek/test-repo → clones to ~/Projects/test-repo
# /code <task in that repo> → launches claude in cloned worktree
```

### Commit
`feat: github integration via gh CLI for repo listing and cloning`

---

## PHASE 6 — HTTP Server + iOS Shortcuts
**Goal:** iOS Shortcut on home screen: tap → speak → Shiro processes → reply spoken back.

### Files
- **NEW** `Sources/Bridge/HTTPRemoteServer.swift` — uses `Network.framework` `NWListener`
- **NEW** `docs/REMOTE.md` — Tailscale + iOS Shortcut setup instructions
- **EDIT** `Sources/App/KeychainHelper.swift` — add `shiroRemoteToken` key
- **EDIT** `Sources/UI/FloatingBar/FloatingBarView.swift` — Settings: Remote Access tab with token reveal/rotate

### Steps

**6.1 — HTTPRemoteServer**
```swift
@MainActor
final class HTTPRemoteServer: ObservableObject, RemoteReplySink {
    @Published var isRunning = false
    @Published var port: UInt16 = 7421

    private var listener: NWListener?
    private var pendingReplies: [String: (String) -> Void] = [:]   // requestId → completion

    func start() throws { /* NWListener on TCP 7421, .interface(.loopback) AND tailscale interface */ }
    func stop() { ... }

    /// Endpoints:
    /// POST /v1/prompt    body: {"text":"...","sync":true|false}    auth: Bearer <token>
    /// GET  /v1/status    (returns running model, queue depth, last cost)
    /// POST /v1/cancel    body: {"id":"..."}
}
```

Use `Network.framework` (Apple-supported, sandbox-friendly). No SwiftNIO dependency.

Auth: validate `Authorization: Bearer <token>` header. Token from keychain.

For sync mode (Shortcut waits for full response): hold the connection open up to 30s, send response when done.

For async mode: return `{"id":"...","status":"queued"}` immediately, Shortcut polls `/v1/status?id=...`.

**6.2 — iOS Shortcut definition**
Document in `docs/REMOTE.md`. The Shortcut:
1. "Dictate Text" action → captures voice
2. "Get Contents of URL" action:
   - URL: `http://your-mac-tailscale-ip:7421/v1/prompt`
   - Method: POST
   - Headers: `Authorization: Bearer <token>`, `Content-Type: application/json`
   - Body: `{"text":"<dictated_text>","sync":true}`
3. "Get Dictionary Value" → `text` field
4. "Speak Text" → speaks reply

Provide a Shortcut iCloud share URL for one-tap install (generated once after testing).

**6.3 — Tailscale doc**
`docs/REMOTE.md` covers:
- Install Tailscale on Mac and iPhone
- Get Mac's Tailscale IP (`tailscale ip -4`)
- Test from phone: `curl http://<tailscale-ip>:7421/v1/status`
- Import iOS Shortcut, set token + IP

**6.4 — Settings UI**
Remote Access tab in Settings:
- Toggle: Enable HTTP server (default off)
- Port (default 7421)
- Token (masked, with "Show" / "Rotate" buttons)
- "Copy curl test command" button
- Status indicator: 🟢 Listening on tailscale-ip:7421 / 🔴 Off

### Verification
```bash
# From iPhone (on tailnet): curl -X POST http://<mac-ip>:7421/v1/prompt -H "Authorization: Bearer <token>" -d '{"text":"what time is it","sync":true}'
# Expected: JSON reply with answer
# From Shortcut: tap → speak → hear reply
```

### Commit
`feat: HTTP remote server + iOS Shortcuts integration`

---

## PHASE 7 — Parent/Sub-Agent System
**Goal:** Shiro can (a) spawn multiple Claude Code subagents in parallel, (b) auto-write subagent definition files for recurring patterns.

### Files
- **NEW** `Sources/Agent/SubAgentManager.swift`
- **NEW** `Sources/Agent/SubAgentSynthesizer.swift`
- **EDIT** `Sources/Agent/CodingOrchestrator.swift` — multi-task path
- **EDIT** `Sources/Bridge/TelegramRelay.swift` — `/multi`, `/agents` commands

### Steps

**7.1 — Multi-task plan**
Extend `CodingPlan`:
```swift
struct MultiCodingPlan: Codable {
    let parentTask: String
    let subtasks: [Subtask]
    let mergeStrategy: MergeStrategy   // .sequentialPRs | .singlePR | .userReview
}
struct Subtask: Codable {
    let title: String
    let prompt: String
    let workspaceId: String       // can be same project, different worktrees
    let branchName: String        // each subtask gets its own worktree
    let dependsOn: [String]       // subtask titles this depends on
    let allowedTools: [String]?
}
```

`CodingOrchestrator.planMulti(task:)` — calls LLM with prompt: "Decompose this task into N parallel subtasks. Each subtask must be independently completable in its own git worktree. Output JSON matching MultiCodingPlan schema."

**7.2 — SubAgentManager**
```swift
@MainActor
final class SubAgentManager: ObservableObject {
    struct ActiveAgent: Identifiable {
        let id: String
        let subtask: Subtask
        let worktreeURL: URL
        var status: Status   // .pending, .running, .succeeded, .failed
        var costUSD: Double
        var startedAt: Date?
        var endedAt: Date?
    }
    @Published var activeAgents: [ActiveAgent] = []

    /// Runs subtasks respecting `dependsOn` DAG. Parallel where possible.
    func executeMulti(_ plan: MultiCodingPlan) async throws { ... }

    /// Cancels a specific agent.
    func cancel(_ id: String) async { ... }

    /// Cancels all.
    func cancelAll() async { ... }
}
```

Use `TaskGroup` with concurrency limit (default: 3 simultaneous, configurable). Each agent = one `ClaudeCodeRunner` invocation in its own worktree.

**7.3 — UI panel**
Add SubAgentsPanel to main window (next to RoutinesView). Live-updating list:
- Tree view: parent task → subtasks
- Each subtask row: title, status spinner/check/cross, cost so far, "View transcript" button
- Aggregate: "$X total / $Y budget"

**7.4 — SubAgentSynthesizer**
Detects recurring patterns and offers to write a subagent definition:
```swift
@MainActor
final class SubAgentSynthesizer: ObservableObject {
    /// Scans last N completed tasks for similarity. Returns suggested agent definitions.
    func suggestAgents(lastN: Int = 30) async -> [SuggestedAgent]

    /// Writes the markdown agent file to ~/.claude/agents/<name>.md (user scope)
    /// or ./.claude/agents/<name>.md (project scope, if requested)
    func writeAgent(_ agent: AgentDefinition, scope: Scope) async throws

    /// Lists existing agent files.
    func listAgents() async throws -> [AgentDefinition]
}

struct SuggestedAgent {
    let name: String
    let description: String
    let allowedTools: [String]
    let model: String?
    let systemPromptDraft: String
    let basedOnTaskIds: [String]  // for explainability
}

struct AgentDefinition {
    let name: String
    let description: String
    let tools: [String]?
    let model: String?
    let bodyMarkdown: String
    let path: URL
}
```

Format for `~/.claude/agents/<name>.md`:
```markdown
---
name: <kebab-case>
description: <one-line, used for activation>
tools: [Read, Edit, Bash]
model: sonnet
---

<system prompt body>
```

Suggester uses LLM call: "Given these N past task descriptions and outcomes, propose 1-3 reusable subagent definitions. Output JSON matching AgentDefinition[]."

**7.5 — Telegram commands**
- `/multi <task>` → planMulti, show plan, approve via inline buttons, kick off
- `/agents` → list current synthesized agents + their usage count
- `/agents-suggest` → run synthesizer, present suggestions

### Verification
```bash
# /multi refactor auth module: split user model, fix tests, update docs
# Expected:
# - 3 subtasks generated
# - 3 worktrees created (parallel)
# - 3 claude processes running concurrently
# - Live status panel updates in main window
# - Final: 3 PR URLs posted to Telegram
```

```bash
# /agents-suggest after a week of usage
# Expected: list of 1-3 proposed agents, e.g.:
#   - "test-runner": runs pytest/vitest, reports failures
#   - "doc-updater": keeps README in sync with code
# Approve → markdown files written to ~/.claude/agents/
```

### Commit
`feat: parent-subagent orchestration + subagent synthesizer`

---

## PHASE 8 — Cost Ceiling + Budget Tracking
**Goal:** Every `/code` invocation has a cost cap. Real-time spend visible. Hard stop when exceeded.

### Files
- **NEW** `Sources/Agent/CostLedger.swift`
- **EDIT** `Sources/Agent/ClaudeCodeRunner.swift` — emit usage events
- **EDIT** `Sources/Memory/Database.swift` — add `cost_records` table
- **EDIT** `Sources/UI/FloatingBar/FloatingBarView.swift` — Settings: Budget tab

### Steps

**8.1 — Cost table**
```swift
struct CostRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "cost_records"
    var id: String
    var taskId: String           // CodingPlan branchName
    var sessionId: String?       // claude session id
    var model: String
    var inputTokens: Int
    var outputTokens: Int
    var costUSD: Double
    var createdAt: Date
}
```

Migration: `CREATE TABLE cost_records (...)`. Add to `ShiroDatabase.migrations`.

**8.2 — CostLedger**
```swift
@MainActor
final class CostLedger: ObservableObject {
    @Published var todaySpend: Double = 0
    @Published var monthSpend: Double = 0

    func recordUsage(taskId: String, sessionId: String?, model: String, input: Int, output: Int) async {
        let cost = ModelPricing.compute(model: model, input: input, output: output)
        // insert into DB
        // update aggregates
    }

    func taskSpend(_ taskId: String) async -> Double { ... }
    func reset() async { /* archive old records */ }
}

enum ModelPricing {
    static func compute(model: String, input: Int, output: Int) -> Double {
        // $/MTok rates per CLAUDE.md
        switch model {
        case "claude-sonnet-4-6": return Double(input) * 3.0/1_000_000 + Double(output) * 15.0/1_000_000
        case "claude-opus-4-6":   return Double(input) * 5.0/1_000_000 + Double(output) * 25.0/1_000_000
        case "claude-haiku-4-5":  return Double(input) * 1.0/1_000_000 + Double(output) * 5.0/1_000_000
        default: return 0
        }
    }
}
```

**8.3 — Wire into runner**
In `ClaudeCodeRunner`, on every `usage` event from JSONL stream → `await costLedger.recordUsage(...)`. After each event, check `await costLedger.taskSpend(taskId) > plan.maxCostUSD` → kill process + log error.

**8.4 — Budget tab in Settings**
- Today: $X.XX
- This month: $Y.YY
- Top 10 most expensive tasks (table)
- Default per-task ceiling slider ($0.50 - $20.00)
- Daily ceiling (default off)
- "Reset month" button

### Verification
```bash
# /code <small task with $0.10 ceiling>
# Expected: runs to completion, cost recorded
# /code <complex task with $0.05 ceiling>
# Expected: killed mid-run with "Budget exceeded" error
# Settings → Budget: shows both records
```

### Commit
`feat: per-task cost ceiling and spend tracking`

---

## PHASE 9 — Polish
**Goal:** Quality-of-life improvements that round out the experience.

### Tasks (in any order)

**9.1 — ⌘K command palette**
Floating bar overlay showing all slash commands + skills + recent prompts. Fuzzy search. Arrow keys + enter.

**9.2 — Voice approval**
When `ApprovalCardView` is shown and STTService is active, listen for "approve" / "deny" / "always" / "never". Resolve approval accordingly.

**9.3 — Workspace presets**
`.shiro/workspace.toml` per-project overrides:
```toml
[shiro]
default_model = "haiku"
allowed_tools = ["Read", "Edit", "Bash"]
max_cost_per_task = 5.00
auto_approve_risk = "low"   # or "med"
```
Loaded by `WorkspacesRegistry` on workspace activation. Settings tab to edit.

**9.4 — Risk-tier customization**
Settings toggle: "Ask before medium-risk actions" (was hardcoded auto-approve in ConsentGate.swift line 134-138).

**9.5 — 3-second veto toast for medium-risk**
When toggle from 9.4 is off but user wants light visibility: brief notification "About to run X — click to veto".

**9.6 — Approval card timeout countdown**
Show "Auto-deny in 4:32" countdown on `ApprovalCardView`.

### Verification
Each subtask gets its own smoke test. Update HANDOFF.md after each.

### Commit (split per subtask)
`feat: command palette ⌘K`
`feat: voice approval via deepgram`
`feat: per-workspace config presets`
`feat: risk-tier customization in settings`
`feat: timeout countdown on approval card`

---

## 🧪 GLOBAL TEST CHECKLIST (run after every phase)

```bash
# 1. Build clean
cd ~/Projects/shiro && swift build 2>&1 | tail -20
# Expected: "Build complete!" with 0 errors

# 2. App launches and stays up
pkill -f "\.build/debug/Shiro"; sleep 1
.build/debug/Shiro &
sleep 3
pgrep -f "\.build/debug/Shiro" && echo "OK" || echo "FAIL"

# 3. Existing functionality regression
# - /forecast AAPL still renders chart (chart_base64 path)
# - ⌘. still toggles floating bar
# - New Routine sheet still works
# - Error Log tab still updates

# 4. Phase-specific test (see each phase's Verification section)

# 5. Commit if all pass
git add -A && git commit -m "<phase commit message>"
```

---

## 📝 HANDOFF.md UPDATE TEMPLATE

After every phase, append:
```markdown
## Session: YYYY-MM-DD HH:MM (Phase N — <title>)

### What Was Done
- [bullet list of concrete changes with file paths]

### What Works (verified)
- [test command] → [expected output, confirmed]

### What's Broken / Blockers
- [list anything pending or partially done]

### Next Steps
1. [specific next action — usually next phase number]

### Files Modified
- path/to/file.swift — what changed
```

---

## 🚨 ESCAPE HATCHES

If you (Sonnet) hit any of these, **STOP and update HANDOFF.md** before continuing:

1. **Build fails 3 times in a row** on the same step → architectural problem; user may need Opus to debug
2. **Test fails after fix attempted twice** → likely missing context; ask user
3. **A phase touches >10 files** → re-scope; phase was too big
4. **Token cost for current session exceeds $5** → stop, save HANDOFF, start fresh session
5. **An external dependency is missing** (no `gh` CLI, no `claude` CLI, no Tailscale) → stop, document, ask user

---

## 🎯 SUCCESS CRITERIA

When all phases done, this works end-to-end:

1. Phone in your pocket. Open Telegram. Send: `/code refactor the auth module in shiro to use async/await`
2. Get plan preview. Tap Approve.
3. On Mac: VS Code window opens at a fresh worktree. Integrated terminal runs `claude` with the prompt.
4. Phone receives streaming updates: tool uses, progress, cost.
5. After 4 minutes: `✅ done in 4:12, $0.34. PR: https://github.com/.../pull/47`
6. You never touched the Mac.

That's the win condition.
