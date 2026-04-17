# Shiro — Master Plan v3 (Fazm-Grounded)
*Local-first AI desktop agent. Built on a surveyed Fazm fork, not a wishlist.*

---

## 0. The Vision — Restated

Shiro is a **local-first autonomous desktop agent** for Abhishek. Built as a direct fork + upgrade of Fazm (`/Users/abhisheksharma/Projects/fazm`, commit on `main`). Where Fazm depends on cloud (Firestore auth, Vertex/Gemini vision, GCS session uploads, Stripe), Shiro is local-only. Where Fazm lacks capability (no sub-agents, no vector RAG, no hooks, no slash commands, no meetings), Shiro adds it.

**One-line pitch:** *A Fazm fork that runs fully on your Mac, remembers everything via hybrid RAG, spawns real parallel sub-agents, and plugs into Composio / GitHub / Context7 MCPs for every tool you need.*

**The benchmark is Fazm, not Jarvis.** Anything Fazm does, Shiro does better-or-equal-but-local. Anything Fazm doesn't do, Shiro adds.

---

## 1. Inspiration Matrix — Corrected After Fazm Code Survey

I surveyed the Fazm checkout at `/Users/abhisheksharma/Projects/fazm`. Reality differs from public impressions. Here's the honest matrix:

| Source | What it ACTUALLY gives us | What it DOESN'T give (we build) |
|--------|---------------------------|----------------------------------|
| **Fazm** *(direct fork base)* | Swift/SwiftUI shell + ACP bridge over stdio + Unix-socket callback → MCP server pattern + LM Studio proxy + SkillInstaller + FTS5 chat search + CoreAudio 16k PCM capture + Deepgram streaming STT + 17 bundled skills in Claude Code format + macOS DistributedNotificationCenter control plane | **No sub-agents** (explicit comment in `acp-bridge/src/index.ts:13`) • **No vector store / embeddings** (only FTS5 + LLM-written KG) • **No hook engine** • **No slash commands** (piggybacks on Claude Code) • **No meeting detection** • **No MCP registry** (hardcoded servers) • Deprecated screen capture API • Cloud-coupled modules (Backend/, Gemini, Firestore, Stripe) |
| **Paperclip** *(task pattern)* | Atomic SQL task checkout (`UPDATE ... WHERE status='todo' RETURNING`), parent/child task trees, approval gates, heartbeat agents, budget/timeout enforcement | We reimplement in Swift+GRDB. Paperclip is TypeScript. |
| **MiroFish** *(memory pattern)* | Zep-style graph memory with real-time updates during ReACT, per-agent personas, interview-any-past-run | Same — reimplement in Swift. |
| **Claude Code** *(power-user surface)* | `.skill.md` file format (Fazm already uses this!), slash commands, hooks, `/compact` semantics | Skill format stays identical to Claude Code → our skills drop into `~/.claude/skills/` and work with Claude Code too. |
| **sqlite-vec + FTS5** *(new — not from any of the four)* | Production-grade local vector store + hybrid BM25+vector retrieval for RAG | Fazm doesn't have this. It's Shiro's moat for your RAG / fine-tuning / coding use cases. |
| **Composio / Context7 / GitHub MCP** *(new)* | 250+ tool integrations, live docs, GitHub ops via MCP | Fazm doesn't bundle these. We do. |

**Design philosophy:**
- **Fork Fazm where it's solid, replace where it's cloud-coupled, extend where it's missing.**
- **Nothing happens without an audit trail** (Paperclip).
- **Memory is the moat** (MiroFish + sqlite-vec).
- **Every action is scriptable** (Claude Code).
- **Local-first is non-negotiable** — the only cloud call is Deepgram (optional, swappable for local whisper.cpp).

---

## 1.5 Fazm Lineage — Fork / Adapt / Skip Matrix

Surveyed on disk at `/Users/abhisheksharma/Projects/fazm`. Decisions I'm making as CTO, per module.

### ✅ FORK (copy + rename to Shiro, minor edits)

| Fazm path | What it does | Shiro mapping |
|-----------|--------------|---------------|
| `acp-bridge/src/fazm-tools-stdio.ts` (828 LOC) | MCP server over stdio with Unix-socket callback into Swift for app-level tools (screenshots, SQL, permissions, etc.) | → `acp-bridge/src/shiro-tools-stdio.ts`. Rename constants, keep pattern. |
| `acp-bridge/src/lm-studio-proxy.ts` | Anthropic ↔ OpenAI format translator. Lets ACP SDK point at LM Studio instead of Anthropic. | → Keep as-is. This is exactly how we plug local models into the agent loop. |
| `acp-bridge/src/protocol.ts` + session demuxing in `index.ts` | Multi-session management (`main`, `observer`, `onboarding` etc.) | → Port to our floating-bar / meeting-mode / observer sessions. |
| `Desktop/Sources/AppDatabase.swift` | GRDB actor + migration pattern | → Copy pattern, replace schema with Shiro's (already have `Database.swift` — reconcile). |
| `Desktop/Sources/SkillInstaller.swift` (~320 LOC) | SHA-checksum-based skill sync from bundle → `~/.claude/skills/` | → Fork verbatim, add Shiro's own bundled skills list. |
| `Desktop/Sources/FileIndexing/*` | File indexer actor + KG storage actors + FTS5 on chat | → Fork. Extend with embedding column for sqlite-vec. |
| `Desktop/Sources/AudioCaptureService.swift` | CoreAudio IOProc, 16-bit PCM @ 16 kHz, no AVAudioEngine Bluetooth gotchas | → Fork. We already have STTService — swap our capture to this pattern. |
| `Desktop/Sources/TranscriptionService.swift` | Deepgram streaming WebSocket client | → Fork. Our `STTService.swift` already does this; consolidate. |
| `Desktop/Sources/Chat/ACPBridge.swift` + `NodeBinaryHelper.swift` | Spawns Node subprocess, manages lifecycle, stdio framing | → Fork. This is how Shiro talks to the agent runtime. |
| `Desktop/Sources/BundledSkills/*.skill.md` (17 files) | YAML-frontmatter skill definitions | → Fork names/structure. Rewrite content for Shiro's use cases (Section 16). |
| `acp-bridge/browser-overlay-init-page.ts` | Playwright overlay injector | → Fork when we ship `browser-agent` skill. |
| macOS `DistributedNotificationCenter` control plane | External scripts post `setModel:`/`newChat`/`sendFollowUp:` | → Fork as `com.shiro.control`. Enables shortcuts, launchd jobs, other apps to drive Shiro. |

### 🔧 ADAPT (pattern is useful, implementation needs change)

| Fazm path | Why adapt | Shiro change |
|-----------|-----------|--------------|
| `buildMcpServers()` in `acp-bridge/src/index.ts:895-1005` | Hardcoded MCP list (playwright, macos-use, whatsapp, google-workspace) | → Replace with `MCPRegistry` reading `~/.shiro/mcp.yaml` — user adds Composio / GitHub / Context7 / HF declaratively. |
| `FloatingControlBar/ScreenCaptureManager.swift` | Uses deprecated `CGWindowListCreateImage` to dodge permission prompt | → Use ScreenCaptureKit (macOS 14+). Accept the permission prompt; we already handle it. |
| `GeminiAnalysisService.swift` | Cloud vision via Gemini Files API | → Replace with local vision via LM Studio (Qwen2.5-VL-7B). Keep the observer loop pattern (60-min accumulation, task-drafting). |
| `observer` session logic (`index.ts:1020-1060`) | Batches every 10 turn-pairs, drafts observer cards | → Adapt for our screen-observer + meeting-observer skills. |
| `inbox/` launchd pipelines | Separate Claude Code processes for email/founder-chat | → Adapt into our hooks engine + scheduled slash commands (`/brief`, `/evening-review`). |

### ❌ SKIP (cloud-coupled or not relevant)

| Fazm path | Why skip |
|-----------|----------|
| `Backend/` (axum + Firestore + Vertex + Stripe) | Cloud relay + billing. Shiro is local-only. No server. |
| `Desktop/Sources/AuthService.swift` | Firestore auth. No accounts in Shiro. |
| `Desktop/Sources/PostHogManager.swift`, `AnalyticsManager.swift`, Sentry | Telemetry to Fazm's account. Remove. |
| `Desktop/Sources/SubscriptionService.swift`, `ReferralService` | Stripe billing. Remove. |
| `SessionRecordingManager.swift` GCS upload path | Remove cloud upload. Keep local H.265 chunking if we ever want session replay (Phase 10+). |
| `web/` Next.js marketing site | Not needed. |
| `inbox/` — `m13v`-specific configs | Matt's email/inbox. Rewrite for Abhishek's context. |

### ⚠️ License caveat

Fazm repo has **no LICENSE file**. README says "fully open source" but that's not legally binding. Before we publish Shiro as derived work, I will:
1. Open a GitHub issue on `mediar-ai/fazm` requesting an explicit OSS license.
2. Until clarified: **Shiro adapts patterns and re-implements in our own source files**. No file-for-file copies into Shiro's repo. This is a slightly slower path but protects us legally.
3. The patterns themselves (ACP stdio + Unix socket callback, SHA-checksummed skill sync, CoreAudio IOProc capture) are not copyrightable as such — safe to use.

---

## 2. The Shiro Experience (what it feels like to use)

> *(Section title updated from "Jarvis Experience" — the benchmark is Fazm-level polish, local-first. Scenarios below unchanged.)*


**Morning scenario (autonomous):**
1. You open your laptop at 9am. Shiro's always-on floating bar pulses green.
2. Shiro greets you via TTS: *"Good morning Abhishek. Yesterday's Fazm deep-dive has 3 open tasks. You have a client call with the Australia team at 11:30 — I prepared a 2-line context brief."*
3. You reply by voice: *"Tell me the brief."* Shiro speaks it aloud.

**Meeting scenario (autonomous):**
1. Shiro's screen observer detects Zoom/Meet/Teams window opens.
2. Auto-activates meeting mode — starts Deepgram streaming transcription.
3. During the meeting, Shiro silently:
   - Transcribes live with speaker diarization
   - Extracts action items as they're spoken ("can you send the doc by Friday" → Task)
   - Extracts decisions into the knowledge graph
   - Flags commitments *you* make
4. When the meeting ends, Shiro shows a summary card with:
   - 3-line recap
   - Action items (yours + others' — approval required before any auto-execution)
   - Updated graph nodes
   - Follow-up email draft (not sent)

**Flow scenario (you're coding):**
1. Shiro's vision observer sees you stuck on a stack trace for 5+ minutes.
2. Subtle notification (no popup): *"I see a KeyError in the logs you're looking at. Want me to search similar patterns in your codebase? (⌘.)"*
3. You hit ⌘. — Shiro spawns a sub-agent that searches, reads relevant files, and proposes a fix.
4. You approve or reject in one keystroke.

**Command scenario (explicit):**
- `/meeting` — start meeting mode now
- `/observe` — toggle screen observer
- `/kg Abhishek` — show all knowledge graph nodes about you
- `/task Review the PR someone opened today` — create a task and run it
- `/skills` — list installed skills
- `/sub "find all uses of deprecated API"` — spawn a sub-agent with that mission
- `/handoff` — write HANDOFF.md for next session

---

## 3. Updated Architecture (Fazm-lineage, local-first)

**Critical architectural decision (as CTO):** We keep Fazm's **Swift shell + Node/TypeScript ACP bridge** split. Reasons:
1. It's already battle-tested in Fazm.
2. The `@agentclientprotocol/claude-agent-acp` SDK + Fazm's `lm-studio-proxy.ts` gives us **free Claude Sonnet integration** the day we need it — user can route hard tasks to Claude while keeping daily loops on LM Studio.
3. MCP servers run as child processes of the Node bridge, not the Swift app — cleaner isolation.
4. The Unix-socket callback pattern lets MCP tools call back into Swift for app-level actions (screenshots, permissions, audio).

Swift owns: UI, DB, capture, OS integration. Node/TS owns: agent loop, MCP orchestration, model routing.

```
┌────────────────────────────────────────────────────────────────────────┐
│                       SHIRO.app (Swift / SwiftUI)                        │
├────────────────────────────────────────────────────────────────────────┤
│  UI LAYER                                                                │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐  │
│  │Floating  │  │Task      │  │Meeting   │  │Graph     │  │Skills    │  │
│  │ Bar      │  │ Board    │  │ Mode     │  │ Viewer   │  │ Browser  │  │
│  └────┬─────┘  └────┬─────┘  └────┬─────┘  └────┬─────┘  └────┬─────┘  │
└───────┼─────────────┼─────────────┼─────────────┼─────────────┼────────┘
        └─────────────┴─────────────┴─────────────┴─────────────┘
                                     │
┌────────────────────────────────────┼───────────────────────────────────┐
│                   SWIFT CORE (in-process with UI)                        │
│  ┌──────────────┐ ┌──────────────┐ ┌──────────────┐ ┌──────────────┐  │
│  │ AppState     │ │ Database     │ │ HookEngine   │ │ SlashCmd     │  │
│  │ (ObservableObject)│ (GRDB)   │ │ (events→cmds)│ │ Parser       │  │
│  └──────────────┘ └──────────────┘ └──────────────┘ └──────────────┘  │
│  ┌──────────────┐ ┌──────────────┐ ┌──────────────┐ ┌──────────────┐  │
│  │ Capture      │ │ STT          │ │ TTS          │ │ Accessibility│  │
│  │ (ScreenCapKit)│ │ (Deepgram)  │ │ (AVSpeech)   │ │ (AX API)     │  │
│  └──────────────┘ └──────────────┘ └──────────────┘ └──────────────┘  │
└──────────────────┬──────────────────────────────────────────────────────┘
                   │ spawns + stdio + Unix socket
                   ▼
┌─────────────────────────────────────────────────────────────────────────┐
│              SHIRO-BRIDGE  (Node/TypeScript, spawned subprocess)         │
│              — forked from fazm acp-bridge/ —                            │
│  ┌──────────────────────────────────────────────────────────────────┐  │
│  │                      ACP Agent Runtime                            │  │
│  │           (@agentclientprotocol/claude-agent-acp)                 │  │
│  │                                                                    │  │
│  │  ┌─────────────┐  ┌─────────────┐  ┌────────────────────────────┐ │  │
│  │  │ LMStudio    │  │ Ollama      │  │ Anthropic Claude            │ │  │
│  │  │ Proxy       │  │ Proxy       │  │ (optional, user-provided)   │ │  │
│  │  │ (Anthropic↔│  │ (Anthropic↔│  │                              │ │  │
│  │  │  OpenAI fmt)│  │  Ollama)    │  │                              │ │  │
│  │  └─────────────┘  └─────────────┘  └────────────────────────────┘ │  │
│  │                                                                    │  │
│  │  ┌─────────────┐  ┌─────────────┐  ┌────────────────────────────┐ │  │
│  │  │ Session     │  │ SubAgent    │  │ ModelRouter                 │ │  │
│  │  │ Demuxer     │  │ Manager     │  │ (heuristic routing)         │ │  │
│  │  │ (main/obs/  │  │ (SQL atomic │  │                              │ │  │
│  │  │  meeting)   │  │  checkout)  │  │                              │ │  │
│  │  └─────────────┘  └─────────────┘  └────────────────────────────┘ │  │
│  │                                                                    │  │
│  │  ┌─────────────┐  ┌─────────────┐  ┌────────────────────────────┐ │  │
│  │  │ Skill       │  │ MCP         │  │ Memory Client               │ │  │
│  │  │ Dispatcher  │  │ Registry    │  │ (calls shiro-tools for KG + │ │  │
│  │  │             │  │ (yaml-conf) │  │  vector retrieval over UDS) │ │  │
│  │  └─────────────┘  └─────────────┘  └────────────────────────────┘ │  │
│  └──────────────────────────────────────────────────────────────────┘  │
└──────────┬──────────────────────────────────────────────────┬──────────┘
           │ Unix domain socket (SHIRO_BRIDGE_PIPE)            │
           ▼                                                    ▼
  ┌────────────────────────────┐              ┌──────────────────────────┐
  │  shiro-tools MCP server    │              │  External MCP servers     │
  │  (stdio, in-bridge)        │              │  (subprocess per server)  │
  │  • execute_sql             │              │  • playwright             │
  │  • capture_screenshot      │              │  • macos-use              │
  │  • read_file / write_file  │              │  • composio  ★ NEW        │
  │  • search_kg / search_rag  │              │  • github    ★ NEW        │
  │  • ingest_document         │              │  • context7  ★ NEW        │
  │  • save_kg_node            │              │  • huggingface ★ NEW      │
  │  • create_task             │              │  • filesystem             │
  │  • spawn_sub_agent         │              │  • whatsapp (optional)    │
  │  • speak_response          │              │  • gdrive (optional)      │
  │  • check_permission        │              │  — each a child process — │
  └──────────┬─────────────────┘              └──────────────────────────┘
             │ callback via Unix socket → Swift (screenshots, SQL, KG, RAG)
             ▼
┌─────────────────────────────────────────────────────────────────────────┐
│            MEMORY LAYER (single SQLite file + sqlite-vec)                │
│                                                                          │
│  kg_nodes  │ kg_edges  │ tasks  │ task_runs  │ observations             │
│  conversations │ indexed_files │ meeting_sessions │ skills_installed    │
│  approvals │ goals  │ session_snapshots │ hooks_log │ agent_personas    │
│  rag_chunks (sqlite-vec)  │ rag_chunks_fts (FTS5)  │ ingest_jobs  ★ NEW│
│                                                                          │
│  Location: ~/Library/Application Support/Shiro/shiro.db                  │
└─────────────────────────────────────────────────────────────────────────┘
```

**Flow:** user speaks/types → Swift captures → sends via stdio framing to Node bridge → ACP runtime picks skill → calls model (LM Studio local or Claude cloud) → model emits tool calls → bridge routes to appropriate MCP (shiro-tools for app ops, composio for SaaS, playwright for browser, etc.) → shiro-tools calls back via Unix socket into Swift for DB/KG/RAG/screen ops → result flows back up → Swift renders in UI.

---

## 4. Model Backend Abstraction — Forking Fazm's Proxy Pattern

### The key insight from Fazm's code

Fazm uses `@agentclientprotocol/claude-agent-acp` — the SDK that powers Claude Code's agent loop. It expects Anthropic's wire format. Fazm wrote **`acp-bridge/src/lm-studio-proxy.ts`** that translates Anthropic Messages API ↔ OpenAI-compatible format on the fly. This means:
- The agent loop code is identical whether you're running LM Studio, Ollama, or real Anthropic.
- Tool calling just works across backends.
- You can hot-swap models mid-session.

**We fork this proxy verbatim.** It's the most valuable file in Fazm for our purposes. Extend with:
- `ollama-proxy.ts` — same pattern, Ollama API translation.
- `anthropic-passthrough.ts` — direct Claude route (optional, when user provides API key).
- `deepgram-stt-proxy.ts` — already partially exists in Fazm's TranscriptionService; we extract.

### Protocol

```swift
protocol ModelBackend {
    var name: String { get }              // "lmstudio" | "ollama"
    var baseURL: String { get }
    func healthCheck() async -> Bool
    func loadedModels() async -> [ModelInfo]
    func chat(_ request: ChatRequest) async throws -> ChatResponse
    func embed(_ texts: [String]) async throws -> [[Float]]
    func vision(_ prompt: String, image: Data) async throws -> String
    func transcribe(_ audio: Data) async throws -> String  // optional
}
```

### Implementations

**LMStudioBackend** (already built):
- POST /v1/chat/completions (OpenAI format, tool calling, vision)
- POST /v1/embeddings
- POST /v1/audio/transcriptions (whisper)
- GET /v1/models

**OllamaBackend** (new):
- POST /api/chat (Ollama native format — slightly different)
- POST /api/embeddings
- POST /api/generate (for vision via llava, qwen2.5vl, etc.)
- GET /api/tags
- Tool calling: supported on Ollama v0.3+ via `tools:` array
- Quirk: Ollama uses `model` field differently, some models need `format: "json"` flag for reliable tool calls

**DeepgramBackend** (STT only):
- WebSocket wss://api.deepgram.com/v1/listen (streaming, real-time)
- POST https://api.deepgram.com/v1/listen (batch)
- Nova-3 model for best English accuracy + diarization
- Key stored in `.env` as `DEEPGRAM_API_KEY` (already done ✓)

### Routing matrix

```
Task Type          │ Backend           │ Model
───────────────────┼──────────────────┼─────────────────────────────
Reasoning/code     │ LM Studio         │ gemma-4-26b-a4b (18GB)
Fast router/chat   │ LM Studio         │ qwen3-8b (4.6GB)
Vision/screen      │ LM Studio         │ qwen2.5-vl-7b (6GB)
Embeddings         │ LM Studio         │ embeddinggemma-300m (0.2GB)
Streaming STT      │ Deepgram          │ nova-3
Batch STT          │ LM Studio (fallback)│ whisper-large-v3-turbo
TTS                │ macOS AVSpeechSynth│ native (or qwen3-tts in LM)
Offline fallback   │ Ollama            │ whatever's pulled there
```

User-configurable via `~/.shiro/config.yaml`:
```yaml
backends:
  default: lmstudio
  fallback: ollama
  stt: deepgram
  tts: macos

models:
  brain: google/gemma-4-26b-a4b
  fast: qwen/qwen3-8b
  vision: qwen/qwen2.5-vl-7b
  embed: text-embedding-embeddinggemma-300m-qat
```

---

## 5. Meeting Mode — Full Skill-Driven Spec

Meeting mode is the crown jewel — this is where Shiro earns the "Jarvis" title. Fazm has this but it's tied to their cloud. Ours runs fully local + Deepgram for streaming quality.

### Trigger

**Auto-detect:** screen observer sees one of these window titles → meeting skill activates
- `Zoom Meeting` / `Zoom - *` 
- `Google Meet` (Chrome/Safari tab)
- `Microsoft Teams`
- `FaceTime`
- Slack huddle indicators

**Manual:** `/meeting` slash command or push meeting button in floating bar.

### Skill: `meeting-mode`

```yaml
name: meeting-mode
trigger_keywords: ["meeting", "call", "zoom", "teams", "standup"]
trigger_windows: ["Zoom Meeting", "Google Meet", "Microsoft Teams"]
allowed_tools: [stt, tts, knowledge_graph, create_task, calendar, notes]
```

### Pipeline (per-phase)

**PHASE 1: Setup (T-0)**
1. Meeting detector fires
2. Shiro checks calendar (EventKit) for meeting metadata: title, attendees, agenda
3. Queries KG for relevant context: past meetings with same attendees, related projects, open commitments
4. Creates `MeetingSession` row in SQLite with metadata
5. Starts Deepgram streaming WebSocket
6. Shows minimal overlay: "🎙 Recording — meeting-mode active"

**PHASE 2: Live Transcription (during meeting)**
1. Deepgram streams interim + final segments
2. Each final segment:
   - Appended to `meeting_sessions.full_transcript`
   - Passed to **segment analyzer** (fast model, qwen3-8b):
     ```
     Classify this line into: action_item | decision | question | info | off-topic
     Who said it (speaker ID from Deepgram diarization)?
     Does it commit someone to an action?
     ```
   - If `action_item` with confidence > 0.7:
     - Extract: who, what, when
     - Create `Task` row with status=`backlog`, source=`meeting`, linked to meeting session
   - If `decision`: create KG node, link to project
3. Every 2 min:
   - Flush transcript buffer to brain model (gemma-4-26b)
   - Update running summary
   - Detect participants (speaker count + name mentions)
   - Check for your own commitments — flag them separately

**PHASE 3: Post-Meeting (T+end)**
1. Meeting detector sees window closed or you say "stop meeting"
2. Full transcript → brain model for final synthesis:
   - Executive summary (3 lines)
   - Action items table (owner, action, deadline)
   - Decisions log
   - Open questions
   - Follow-up suggestions
3. KG extraction: new people, new projects, new relationships
4. **Approval gate**: Shiro shows post-meeting card with:
   - [ ] Auto-create tasks for action items assigned to me
   - [ ] Auto-send follow-up email summary to attendees
   - [ ] Update calendar with decisions
   - [ ] Save transcript to Notes
5. Nothing executes until you click approve/reject per item.

**Files created per meeting:**
- `meeting_sessions` row (DB)
- `tasks` rows (one per approved action item)
- KG node updates
- Optional: `~/Library/Application Support/Shiro/meetings/YYYY-MM-DD-HHMM-<slug>.md` transcript

### Skill composition

Meeting-mode skill composes sub-skills:
- `action-item-extractor` — one-shot classifier
- `decision-extractor` — identifies committed decisions
- `participant-identifier` — builds speaker map
- `follow-up-drafter` — optional email draft
- `calendar-updater` — optional cal event update

Each is a separate `.skill.md` in `~/.shiro/skills/meeting/`.

---

## 6. Skills System (Fazm + Claude Code hybrid)

### Concept

A **skill** is a self-contained capability the agent can invoke. Each skill:
1. Has trigger keywords/conditions
2. Declares required tools
3. Has a system prompt template
4. May compose other skills
5. Can be hot-loaded from markdown files

### Format (one file per skill)

```markdown
---
name: meeting-mode
description: Record, transcribe, and summarize meetings
trigger_keywords: ["meeting", "call", "zoom"]
trigger_windows: ["Zoom Meeting", "Google Meet"]
allowed_tools: [stt, tts, knowledge_graph, create_task, calendar]
requires_approval: [send_email, create_calendar_event]
---

# Meeting Mode

You are Shiro in meeting-mode. Your job is to:
1. Listen silently
2. Transcribe accurately
3. Extract action items and decisions
4. Build context in the knowledge graph
5. NEVER interrupt the meeting
6. After meeting ends, produce summary + action items with approval gates

[detailed instructions for the model...]
```

### Bundled skills (v1) — *core / system*

| Skill | Purpose | Trigger |
|-------|---------|---------|
| `meeting-mode` | Meeting transcription + extraction | window title OR `/meeting` |
| `screen-observer` | Analyze screen, detect stuck patterns | always-on (configurable) |
| `file-indexer` | Watch + summarize new files | FSEvents |
| `deep-research` | Multi-step research with sub-agents | `/research <topic>` |
| `email-drafter` | Draft + send emails (with approval) | `/email` or KG inference |
| `task-manager` | Create, list, complete tasks | `/task` |
| `kg-query` | Query knowledge graph | `/kg <topic>` |
| `calendar-agent` | Read/write calendar | `/cal` |
| `code-reviewer` | Review git diff or PR | `/review` |
| `commit-writer` | Write git commit messages | `/commit` |
| `handoff-writer` | Write HANDOFF.md | `/handoff` |
| `system-control` | Open apps, click, type (accessibility) | `/do <action>` |
| `browser-agent` | Navigate, extract, fill forms | `/browse <task>` |
| `note-taker` | Write to Apple Notes | `/note` |
| `morning-briefing` | Daily context summary | 9am auto-fire OR `/brief` |

> **Domain-specific skill packs for your actual work (teaching, YouTube, automation, AI engineering, freelance, company) are defined in Section 16 below.**

### Skill discovery

On every user query, Shiro:
1. Parses for slash commands (explicit)
2. Scans for trigger keywords (implicit)
3. Matches against active window (context)
4. Picks the most specific matching skill
5. Falls back to "default agent" (no skill) if nothing matches

Only loads the matched skill's system prompt + its allowed tools. Keeps context window clean.

---

## 7. Sub-Agent System — Shiro's Edge Over Fazm

**This is where we go beyond Fazm.** Fazm's own code is explicit (`acp-bridge/src/index.ts:13-16`):
> *"session/prompt drives one or more internal Anthropic API calls (initial response + one per tool-use round)… There are no separate sub-agents."*

Fazm has parallel **sessions** (main, observer, onboarding), but no true in-process sub-agent spawning, no task-based atomic checkout, no depth/budget guards. Their "agents" are external launchd-scheduled Claude Code processes.

**Shiro implements the real thing** — the pattern comes from Paperclip, not Fazm.

### The key insight

A sub-agent is just a task row with `parent_task_id` set, running on its own model inference chain within the same Node bridge process. Atomic SQL checkout prevents double-work. Each sub-agent can spawn its own sub-agents (bounded by `max_depth`). Multiple sub-agents run concurrently on Node's event loop — LM Studio / Ollama queue the inference requests, but the coordinator is parallel.

### Spawning flow

```
Main Agent (gemma-4-26b)
│
├─ decides: "I need to research X in parallel"
├─ calls tool: spawn_sub_agent(title, description, skill?)
│
├─ SubAgentManager:
│    1. Creates Task row with:
│       - parent_task_id = current task
│       - status = "todo"
│       - source = "sub_agent"
│       - skill = "deep-research" (if specified)
│    2. Atomic SQL UPDATE: claim task, set agent = "sub_" + UUID
│    3. Spawns new inference chain (fresh context, persona-tuned)
│    4. Sub-agent runs ReACT loop on its own description
│    5. Sub-agent writes result back to task.result, status = "done"
│    6. Main agent receives result string, continues
│
└─ meanwhile, other sub-agents may run in parallel
     (LM Studio queues requests, bounded by max_sub_agents=3)
```

### Sub-agent persona (MiroFish-inspired)

Each spawned sub-agent gets a persona injected at the top of its system prompt:

```
You are a specialist sub-agent: "research-scout".
Your character:
  - Fast, thorough, skeptical
  - Returns structured findings (not prose)
  - Cites sources with exact URLs/paths
  - Admits uncertainty explicitly
Your one task: {description}
Parent task context: {parent_task_title}
Report back when done. Do NOT spawn more than {remaining_depth} sub-agents.
```

Other personas: `code-finder`, `debugger`, `summarizer`, `planner`, `critic`, `action-item-extractor`.

### Budget/limits (Paperclip-inspired, but free since local)

Even though inference is free, runaway sub-agent recursion is a real risk. Limits:
- `max_sub_agents_concurrent = 3`
- `max_sub_agent_depth = 3` (sub can spawn sub-sub, but not sub-sub-sub)
- `max_iterations_per_subagent = 10`
- `max_total_tokens_per_run = 200000` (context-window budget, not dollar budget)
- Hard timeout: 5 min per sub-agent

All enforced in `SubAgentManager.swift`, logged to `task_runs` table.

### Interview any past sub-agent (MiroFish pattern)

Every sub-agent run is archived with:
- Full conversation (in `conversations` table)
- Final result
- Tool calls made
- Token counts

You can ask: *"Show me what the sub-agent did for task T-42"* and get the full trace. Or better: *"Interview that sub-agent — ask it why it chose X"*. Shiro replays the conversation and invites the persona to answer from its now-frozen state.

---

## 8. ReACT Loop with Live Memory Updates (MiroFish pattern)

Every ReACT iteration:
1. **Observe** — pull: recent observations, KG context for query, open tasks, screen state
2. **Think** — brain model decides next action (text response OR tool call)
3. **Act** — execute tool, get result
4. **Update** — *crucial MiroFish addition* — immediately extract entities/relationships from the result and patch the KG:
   ```swift
   // After every tool call:
   Task { 
     await kg.extractAndStore(
       text: toolResult, 
       source: "tool:\(toolName)"
     ) 
   }
   ```
   This runs async, doesn't block the main loop. But it means by the end of a 10-iteration run, the KG has absorbed everything.

### Context assembly per iteration

```
SYSTEM PROMPT ─────
  [Global Shiro persona]
  [Current skill system prompt if any]
  [Available tools (filtered by skill)]

CONTEXT INJECTION ─────
  ## Relevant Knowledge Graph
  [5-8 most relevant KG nodes + their edges, via embedding search on query]
  
  ## Recent Screen Observations (last 5 min)
  [compressed summaries, not raw frames]
  
  ## Open Tasks (max 10)
  [title, status, deadline if any]
  
  ## Current User State
  [active app, window title, time of day]

CONVERSATION ─────
  [last N user/assistant turns, compacted if > threshold]

CURRENT USER MESSAGE ─────
  {the actual query}
```

Token budget: cap at 80K of the 100K gemma context. Leaves room for generation.

---

## 9. Slash Commands (Claude Code pattern)

Slash commands are shortcuts to skills or complex actions. Parsed client-side in the floating bar.

**Registered commands:**
```
/meeting        start meeting mode now
/observe        toggle screen observer on/off
/listen         push-to-talk recording
/task <desc>    create a task (optionally auto-run it)
/sub <mission>  spawn a sub-agent with that mission
/kg <topic>     show knowledge graph context for topic
/cal            today's calendar
/brief          morning briefing
/email <to>     draft an email (doesn't send)
/commit         write a git commit for staged changes
/review         review current git diff or PR
/research <topic>  deep-research with multiple sub-agents
/handoff        write HANDOFF.md
/compact        compact session context
/clear          wipe session, fresh start
/skills         list all skills + show which are active
/status         health of all backends + models
/speak <text>   speak this text via TTS
/watch <path>   add a path to file watcher
/tts on/off     enable/disable TTS responses
/model <name>   switch active brain model
/backend lmstudio|ollama  switch model backend
```

### User-defined slash commands

`~/.shiro/commands/<name>.md` — same format as Claude Code:
```markdown
---
name: daily-standup
description: Generate a standup based on yesterday's commits and today's calendar
---
Read yesterday's commits via git log, today's calendar events via /cal,
and draft a 3-point standup (Yesterday / Today / Blockers). Save to Notes.
```

---

## 10. Hooks System (Claude Code pattern)

Hooks let you wire automated behaviors to events. Config in `~/.shiro/settings.json`:

```json
{
  "hooks": {
    "OnMeetingEnd": [
      { "command": "shiro-export-transcript", "args": ["--format", "markdown"] }
    ],
    "OnStuckDetected": [
      { "command": "shiro-notify", "args": ["--tone", "gentle"] }
    ],
    "PreToolUse": [
      { "matcher": "shell", "command": "shiro-confirm-destructive", "blocking": true }
    ],
    "PostToolUse": [
      { "matcher": "write_file", "command": "shiro-log-change" }
    ],
    "OnTaskComplete": [
      { "matcher": "priority=urgent", "command": "shiro-speak", "args": ["Task done"] }
    ],
    "SessionStart": [
      { "command": "shiro-load-handoff" }
    ],
    "OnNewFile": [
      { "matcher": "**/*.md", "command": "shiro-index-file" }
    ]
  }
}
```

**Events emitted:**
- `SessionStart` / `SessionEnd`
- `PreToolUse` / `PostToolUse` (with matcher on tool name)
- `OnMeetingStart` / `OnMeetingEnd`
- `OnStuckDetected`
- `OnTaskCreate` / `OnTaskComplete`
- `OnNewFile` / `OnFileModified`
- `OnSubAgentSpawn` / `OnSubAgentComplete`
- `OnScreenChange` (throttled)
- `OnApproval` (when user approves/rejects)

---

## 11. Knowledge Graph — Deeper Than v1

### Extended schema

```sql
-- Nodes now have a richer type taxonomy
-- type: person | project | concept | tool | file | meeting | task | commitment | place | event

-- New: goals (Paperclip pattern)
CREATE TABLE goals (
  id TEXT PRIMARY KEY,
  title TEXT NOT NULL,
  description TEXT,
  parent_goal_id TEXT REFERENCES goals(id),
  status TEXT DEFAULT 'active',  -- active | achieved | abandoned
  target_date DATE,
  created_at DATETIME DEFAULT CURRENT_TIMESTAMP
);

-- New: approvals (Paperclip pattern)
CREATE TABLE approvals (
  id TEXT PRIMARY KEY,
  action_type TEXT NOT NULL,     -- send_email | delete_file | run_command | create_calendar_event
  payload_json TEXT NOT NULL,
  status TEXT DEFAULT 'pending', -- pending | approved | rejected | cancelled
  source_task_id TEXT REFERENCES tasks(id),
  requested_at DATETIME DEFAULT CURRENT_TIMESTAMP,
  resolved_at DATETIME
);

-- New: skills (installed skill registry)
CREATE TABLE skills_installed (
  id TEXT PRIMARY KEY,
  name TEXT UNIQUE NOT NULL,
  version TEXT,
  path TEXT NOT NULL,  -- path to .skill.md file
  trigger_keywords_json TEXT,
  trigger_windows_json TEXT,
  allowed_tools_json TEXT,
  enabled BOOLEAN DEFAULT 1,
  installed_at DATETIME DEFAULT CURRENT_TIMESTAMP
);

-- New: session snapshots (for /compact and /handoff)
CREATE TABLE session_snapshots (
  id TEXT PRIMARY KEY,
  session_id TEXT NOT NULL,
  summary TEXT NOT NULL,
  compacted_conversation TEXT,
  open_tasks_json TEXT,
  created_at DATETIME DEFAULT CURRENT_TIMESTAMP
);

-- New: hooks log (audit trail)
CREATE TABLE hooks_log (
  id TEXT PRIMARY KEY,
  event TEXT NOT NULL,
  hook_command TEXT NOT NULL,
  success BOOLEAN,
  output TEXT,
  triggered_at DATETIME DEFAULT CURRENT_TIMESTAMP
);
```

### Real-time KG updates

Inspired by MiroFish's `zep_graph_memory_updater.py`:

- Every tool result → async entity extraction → KG upsert
- Every meeting segment → entity extraction → KG upsert
- Every screen analysis → KG upsert ("user working on X in Y")
- Every conversation turn → KG upsert

The KG is the single source of truth for *structured* "what Shiro knows about Abhishek's world." But structured graph alone is not enough for RAG — we need the unstructured vector side too.

---

## 11.5. Vector RAG Stack — sqlite-vec + FTS5 Hybrid

**This is what Fazm doesn't have.** Fazm's retrieval is FTS5 keyword + SQL WHERE — fine for chat history, useless for semantic RAG over your codebase, papers, or client docs.

Shiro ships a production-grade local RAG stack as a core primitive, not an afterthought. Every skill (rag-builder, paper-reader, code-along, study-mode, agent-trace-reader) sits on top of it.

### Stack

```
┌─────────────────────────────────────────────────────────────┐
│                    INGESTION PIPELINE                        │
│  File → Chunker → Embedder → Vector + FTS insert            │
│                                                              │
│  Chunkers (pick per file type):                              │
│    • code:      tree-sitter AST chunking (function-aware)   │
│    • markdown:  heading-hierarchy chunking                   │
│    • pdf:       layout-aware (Marker or pdfminer)           │
│    • prose:     semantic chunking (avg 400 tokens)           │
│    • transcript: speaker-turn chunking                       │
│                                                              │
│  Embedder:                                                   │
│    • embeddinggemma-300m (LM Studio, 768-dim)               │
│    • or user-configurable (bge-m3, mxbai-embed-large)       │
│                                                              │
│  Metadata tags: corpus_id, source_path, chunk_type,         │
│                 workspace, created_at, hash                  │
└─────────────────────────────────────────────────────────────┘
                             │
                             ▼
┌─────────────────────────────────────────────────────────────┐
│                   STORAGE (same shiro.db)                    │
│                                                              │
│  rag_chunks            rag_chunks_vec         rag_chunks_fts │
│  ─────────────         ───────────────         ─────────── │
│  id PK                 sqlite-vec virtual      FTS5 virtual  │
│  corpus_id             • embedding (f32[768]) • content      │
│  source_path           • chunk_id FK           • tokenized   │
│  content                                                     │
│  metadata JSON                                               │
│  hash                                                        │
│  created_at                                                  │
└─────────────────────────────────────────────────────────────┘
                             │
                             ▼
┌─────────────────────────────────────────────────────────────┐
│                  HYBRID RETRIEVAL                            │
│                                                              │
│  Query →                                                     │
│    1. Embed query                                            │
│    2. Vector ANN: top-K (default 20) from sqlite-vec         │
│    3. BM25: top-K from rag_chunks_fts                        │
│    4. Reciprocal Rank Fusion (RRF) merge → top-N (default 8) │
│    5. Optional rerank: cross-encoder via fast model          │
│    6. Return chunks + metadata + scores                      │
│                                                              │
│  Filters supported: corpus_id, workspace, date range, tags   │
└─────────────────────────────────────────────────────────────┘
```

### Schema additions

```sql
-- Chunks table (content + metadata)
CREATE TABLE rag_chunks (
  id TEXT PRIMARY KEY,
  corpus_id TEXT NOT NULL,          -- e.g. "codebase:shiro", "papers:rag", "client:acme"
  source_path TEXT,                  -- original file path / URL
  source_type TEXT,                  -- file | url | chat | meeting | note
  chunk_index INTEGER NOT NULL,
  content TEXT NOT NULL,
  metadata_json TEXT,                -- chunk_type, line range, headings, speaker, etc.
  content_hash TEXT NOT NULL,        -- for dedup
  workspace TEXT,                    -- company | freelance | own | personal | NULL
  created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
  UNIQUE(corpus_id, content_hash)
);

-- Vector index (sqlite-vec extension, loaded at DB open)
CREATE VIRTUAL TABLE rag_chunks_vec USING vec0(
  chunk_id TEXT PRIMARY KEY,
  embedding FLOAT[768]
);

-- Full-text index (SQLite FTS5)
CREATE VIRTUAL TABLE rag_chunks_fts USING fts5(
  content,
  content=rag_chunks,
  content_rowid=rowid,
  tokenize='porter unicode61'
);

-- Ingest job tracking
CREATE TABLE ingest_jobs (
  id TEXT PRIMARY KEY,
  corpus_id TEXT NOT NULL,
  source_path TEXT NOT NULL,
  status TEXT DEFAULT 'queued',      -- queued | running | done | failed
  chunks_total INTEGER,
  chunks_processed INTEGER,
  error TEXT,
  started_at DATETIME,
  completed_at DATETIME
);

-- Corpora registry (groups chunks into queryable collections)
CREATE TABLE corpora (
  id TEXT PRIMARY KEY,
  name TEXT UNIQUE NOT NULL,
  description TEXT,
  embedding_model TEXT NOT NULL,     -- can't mix embed models in one corpus
  workspace TEXT,
  auto_watch_path TEXT,              -- FSEvents watch root (optional)
  created_at DATETIME DEFAULT CURRENT_TIMESTAMP
);
```

### Tools exposed to the agent (shiro-tools MCP)

```
search_rag(query, corpus_id?, workspace?, top_k?, rerank?) → chunks[]
ingest_document(path, corpus_id, chunk_strategy?)         → ingest_job_id
ingest_url(url, corpus_id)                                 → ingest_job_id
list_corpora()                                             → corpora[]
create_corpus(name, embedding_model, auto_watch_path?)    → corpus_id
delete_corpus(corpus_id)                                   → ok
ingest_status(ingest_job_id)                               → status
```

### Default corpora Shiro auto-creates

| Corpus | Auto-watch | Purpose |
|--------|-----------|---------|
| `codebase` | configurable per project | Your code — feeds `code-along`, `commit-writer`, `code-reviewer` |
| `papers` | `~/Documents/Papers/` | AI papers — feeds `paper-reader`, `study-mode`, `rag-builder` |
| `clients` | `~/Documents/Clients/` | Per-client docs (tagged by workspace) |
| `meetings` | auto (from meeting-mode) | All meeting transcripts |
| `notes` | `~/Library/Application Support/Shiro/notes/` | Personal notes |
| `screen-history` | auto (from screen-observer) | Compressed summaries of what you've been doing |
| `chat-history` | auto | Past Shiro conversations |

**Isolation:** every corpus is addressable by `corpus_id`. RAG queries default to current-workspace corpora only. Cross-corpus search with explicit `--all` flag.

### Integration with skills

- `rag-builder` skill (Section 16.4) — uses `create_corpus` + `ingest_document` to let you build custom RAG on any folder.
- `paper-reader` — auto-ingests any PDF you drop on Shiro into `papers` corpus, then conversations use `search_rag`.
- `ask-my-memory` (common skill) — hybrid search across all current-workspace corpora + KG.
- `agent-trace-reader` — ingests LangSmith/Langfuse traces into a `traces` corpus, queryable later.

### Implementation cost

- `sqlite-vec`: single C extension, ~300KB, loaded at DB open with `conn.enableExtensions()`. Swift+GRDB supports this out of the box.
- No separate process, no separate port, no Docker, no embedded Qdrant. One SQLite file holds it all.
- Embedding throughput: ~500 chunks/min on M5 with embeddinggemma-300m. Overnight ingestion of a 50K-chunk codebase.

---

## 11.6. MCP Ecosystem — Going Beyond Fazm's Hardcoded List

Fazm hardcodes 5 MCP servers in `buildMcpServers()` (playwright, macos-use, whatsapp, google-workspace, fazm-tools). Shiro makes MCP first-class and user-extensible.

### `~/.shiro/mcp.yaml` — declarative registry

```yaml
servers:
  # ——— bundled (ship with Shiro) ———
  shiro_tools:
    transport: stdio
    bundled: true
    allowed_in_sessions: [main, observer, meeting, subagent]

  playwright:
    transport: stdio
    command: npx
    args: ["-y", "@playwright/mcp@latest"]
    allowed_in_sessions: [main, subagent]

  macos_use:
    transport: stdio
    bundled_binary: true
    path: ~/Library/Application Support/Shiro/bin/macos-use-mcp
    allowed_in_sessions: [main, subagent]

  # ——— user-configurable (bundled but need token) ———
  github:
    transport: stdio
    command: npx
    args: ["-y", "@modelcontextprotocol/server-github"]
    env:
      GITHUB_PERSONAL_ACCESS_TOKEN: ${GITHUB_TOKEN}
    allowed_in_sessions: [main, subagent]
    skills_using: [commit-writer, code-reviewer, pr-drafter]

  composio:
    transport: stdio
    command: npx
    args: ["-y", "@composio/mcp@latest"]
    env:
      COMPOSIO_API_KEY: ${COMPOSIO_API_KEY}
    allowed_in_sessions: [main, subagent]
    skills_using: [email-drafter, note-taker, workflow-designer, client-followup]

  context7:
    transport: stdio
    command: npx
    args: ["-y", "@upstash/context7-mcp@latest"]
    allowed_in_sessions: [main, subagent]
    skills_using: [rag-builder, ai-eng-research, n8n-node-lookup, vapi-agent-builder]

  huggingface:
    transport: stdio
    command: npx
    args: ["-y", "@huggingface/mcp-server@latest"]
    env:
      HF_TOKEN: ${HF_TOKEN}
    allowed_in_sessions: [main, subagent]
    skills_using: [fine-tune-plan, embedding-bench, vector-db-compare]

  filesystem:
    transport: stdio
    command: npx
    args: ["-y", "@modelcontextprotocol/server-filesystem", "~/Projects", "~/Documents"]
    allowed_in_sessions: [main, subagent]

  # ——— optional (user flips on) ———
  whatsapp:
    enabled: false
    transport: stdio
    bundled_binary: true

  notion:
    enabled: false
    transport: stdio
    command: npx
    args: ["-y", "@notionhq/mcp-server"]
    env: { NOTION_TOKEN: ${NOTION_TOKEN} }
```

### Why Composio matters specifically

Composio is one OAuth config → 250+ apps (Slack, Gmail, Linear, Notion, Calendar, HubSpot, Stripe, etc.). Instead of writing custom MCP servers for each, you get them all. For your freelance / company / own-company work, this collapses dozens of integration tasks into zero code. Your `client-followup` skill just calls `composio.slack.send_message` or `composio.gmail.create_draft` — no custom code.

### Per-skill MCP allow-listing

Each `.skill.md` declares which MCP tools it may call. The bridge enforces this at dispatch time. Example:

```markdown
---
name: commit-writer
description: Write conventional-commits messages for staged diff
allowed_mcp_tools:
  - shiro_tools.execute_shell     # git diff --cached
  - shiro_tools.create_task
  - github.create_pull_request    # optional
trigger_keywords: ["commit", "commit message"]
---
```

### MCP health monitoring

Swift's `MCPSupervisor.swift` watches the bridge's MCP children: restarts crashed servers, logs per-server tool-call counts + latency to `mcp_health` table, surfaces red/green status in `/status` slash command.

---

## 12. File Layout (updated)

```
~/Projects/shiro/
├── PLAN.md                                 ← this document
├── CLAUDE.md                                ← rules for Claude when helping on Shiro
├── HANDOFF.md                               ← session handoffs
├── .env                                     ← DEEPGRAM_API_KEY, etc. (gitignored)
├── .gitignore
├── Package.swift
├── Sources/
│   ├── App/
│   │   ├── ShiroApp.swift                   ✓
│   │   ├── AppState.swift                   ✓
│   │   ├── Config.swift                     ✓
│   │   ├── Info.plist                       ✓
│   │   └── SettingsStore.swift              ← reads ~/.shiro/config.yaml
│   │
│   ├── Bridge/                                 ← Swift ↔ Node bridge plumbing
│   │   ├── ACPBridge.swift                  ← NEW (fork Fazm — spawn Node, stdio framing)
│   │   ├── NodeBinaryHelper.swift           ← NEW (fork Fazm — bundled Node runtime)
│   │   ├── BridgeSocketServer.swift         ← NEW (Unix socket server for MCP→Swift callbacks)
│   │   ├── MCPSupervisor.swift              ← NEW (watches MCP children, restart on crash)
│   │   ├── ModelBackend.swift               ← NEW protocol (for Swift-side probing only)
│   │   ├── LMStudioClient.swift             ✓ (keep for Swift-side probing, stats, models list)
│   │   ├── DeepgramClient.swift             ← NEW (extract from STT)
│   │   └── TTSService.swift                 ← NEW (macOS speech + LM TTS)
│   │
│   ├── Memory/
│   │   ├── Database.swift                   ✓ (extend with sqlite-vec extension load)
│   │   ├── KnowledgeGraph.swift             ✓
│   │   ├── VectorStore.swift                ← NEW (sqlite-vec wrapper)
│   │   ├── RAGRetriever.swift               ← NEW (hybrid BM25 + vec + RRF + rerank)
│   │   ├── Ingestor.swift                   ← NEW (chunk + embed + dedup + index)
│   │   ├── Chunkers/
│   │   │   ├── CodeChunker.swift            ← NEW (tree-sitter)
│   │   │   ├── MarkdownChunker.swift        ← NEW
│   │   │   ├── PDFChunker.swift             ← NEW
│   │   │   └── ProseChunker.swift           ← NEW
│   │   ├── CorpusManager.swift              ← NEW (corpora registry + auto-watch)
│   │   ├── TaskManager.swift                ← NEW (state machine, atomic checkout)
│   │   ├── ApprovalManager.swift            ← NEW
│   │   ├── GoalManager.swift                ← NEW
│   │   └── SessionManager.swift             ← NEW (snapshots, /compact, /handoff)
│   │
│   ├── Perception/
│   │   ├── STTService.swift                 ✓
│   │   ├── ScreenCaptureService.swift       ✓
│   │   ├── FileWatcher.swift                ← NEW
│   │   ├── MeetingDetector.swift            ← NEW
│   │   └── BrowserObserver.swift            ← NEW (Playwright MCP bridge)
│   │
│   ├── Agent/
│   │   ├── AgentCoordinator.swift           ✓
│   │   ├── SubAgentManager.swift            ← NEW (spawn, lifecycle, budget)
│   │   ├── AgentPersonas.swift              ← NEW (persona library)
│   │   ├── ModelRouter.swift                ← NEW (extract from LMStudioClient)
│   │   ├── HooksEngine.swift                ← NEW
│   │   └── SlashCommandParser.swift         ← NEW
│   │
│   ├── Skills/
│   │   ├── SkillRegistry.swift              ← NEW (discover, load, match)
│   │   ├── SkillDefinition.swift            ← NEW (parse .skill.md)
│   │   ├── SkillDispatcher.swift            ← NEW
│   │   └── bundled/                          ← ships with the app
│   │       ├── meeting-mode.skill.md
│   │       ├── screen-observer.skill.md
│   │       ├── file-indexer.skill.md
│   │       ├── deep-research.skill.md
│   │       ├── email-drafter.skill.md
│   │       ├── morning-briefing.skill.md
│   │       ├── commit-writer.skill.md
│   │       ├── handoff-writer.skill.md
│   │       └── ... (15 total)
│   │
│   ├── Tools/
│   │   ├── ToolRegistry.swift               ← NEW
│   │   ├── tools/
│   │   │   ├── ShellTool.swift
│   │   │   ├── FileTool.swift
│   │   │   ├── WebSearchTool.swift
│   │   │   ├── CalendarTool.swift (EventKit)
│   │   │   ├── NotesTool.swift (AppleScript)
│   │   │   ├── GitTool.swift
│   │   │   └── AccessibilityTool.swift (macOS control)
│   │   └── mcp/
│   │       ├── MCPClient.swift              ← stdio JSON-RPC bridge
│   │       └── servers/
│   │           ├── playwright.yaml
│   │           └── macos-use.yaml
│   │
│   └── UI/
│       ├── FloatingBar/
│       │   ├── FloatingBarWindowController.swift ✓
│       │   ├── FloatingBarView.swift             ✓
│       │   ├── ChatArea.swift
│       │   └── StatusDot.swift
│       ├── TaskBoard/
│       │   ├── TaskBoardWindow.swift
│       │   └── TaskCard.swift
│       ├── MeetingMode/
│       │   ├── MeetingOverlay.swift         ← minimal overlay during meeting
│       │   └── PostMeetingCard.swift        ← approval gate UI
│       ├── KnowledgeGraph/
│       │   └── GraphViewer.swift            ← SwiftUI + D3-like layout
│       ├── Skills/
│       │   └── SkillsBrowser.swift
│       └── Settings/
│           └── SettingsView.swift
│
├── Resources/
│   ├── Assets.xcassets/
│   ├── Sounds/                              ← notification sounds
│   └── Node/                                ← bundled Node.js runtime (~40MB)
│       ├── bin/node
│       └── README.md
│
├── acp-bridge/                              ← ★ NEW — forked from Fazm
│   ├── package.json
│   ├── tsconfig.json
│   ├── src/
│   │   ├── index.ts                         ← ACP session demuxer + main loop
│   │   ├── protocol.ts                      ← wire types (Swift ↔ Node)
│   │   ├── shiro-tools-stdio.ts             ← app-level MCP tools (fork fazm-tools)
│   │   ├── lm-studio-proxy.ts               ← fork verbatim (Anthropic ↔ OpenAI)
│   │   ├── ollama-proxy.ts                  ← ★ NEW (Anthropic ↔ Ollama)
│   │   ├── sub-agent-manager.ts             ← ★ NEW (atomic checkout + parallel)
│   │   ├── mcp-registry.ts                  ← ★ NEW (reads ~/.shiro/mcp.yaml)
│   │   ├── skill-dispatcher.ts              ← matches skills, filters tools
│   │   ├── model-router.ts                  ← heuristic brain/fast/vision
│   │   ├── kg-client.ts                     ← calls into Swift via UDS
│   │   ├── rag-client.ts                    ← search_rag / ingest_document
│   │   └── session-store.ts                 ← /compact snapshots
│   └── dist/                                ← tsc output, shipped in app
│
├── mcp-servers-bundled/                     ← ★ NEW — binaries we ship
│   ├── macos-use-mcp                        ← accessibility binary
│   └── whatsapp-mcp                         ← optional
│
└── ~/.shiro/                                 ← user config dir
    ├── config.yaml                          ← model prefs, workspace map, audio
    ├── mcp.yaml                             ← ★ NEW — MCP server registry
    ├── settings.json                        ← hooks config
    ├── workspaces.yaml                      ← path → workspace mapping
    ├── skills/                              ← user-added skills
    ├── commands/                            ← user-defined slash commands
    ├── corpora/                             ← per-corpus config (embed model, watch paths)
    ├── journal/                             ← daily-log output
    ├── meetings/                            ← meeting transcript markdowns
    ├── handoffs/                            ← archived HANDOFF.md snapshots
    └── shiro.db                             ← SQLite + sqlite-vec (single file)
```

---

## 13. Build Phases (reprioritized)

### Phase legend
- ✅ done • 🚧 next up • 📋 planned • 🎯 exit criteria = how we know it's done

### ✅ Phase 0 — Foundation (DONE — what currently exists)
- Swift Package + project structure
- SQLite schema + GRDB async
- LM Studio client (direct, not through ACP yet)
- STT service (Deepgram streaming + whisper fallback)
- Screen capture + Qwen2.5-VL analysis
- Knowledge graph CRUD + embeddings + cosine similarity
- Basic ReACT agent coordinator with 8 tools + basic sub-agent
- Floating bar UI
- **Gap:** direct LM Studio calls from Swift, no Node bridge, no vector store, no MCP, no hooks, no skills

---

### 🚧 Phase 1 — Fork Fazm's Node Bridge (the architectural pivot)
*Why first: every later phase assumes the bridge exists. Doing this second would require rewriting Phase 2–5.*

**Scope:**
1. Create `acp-bridge/` directory at repo root, port Fazm's package.json + tsconfig
2. Fork `acp-bridge/src/index.ts` → rename to Shiro, strip Fazm account code
3. Fork `lm-studio-proxy.ts` verbatim (Anthropic ↔ OpenAI translation)
4. Fork `protocol.ts` for Swift ↔ Node message types
5. Fork `shiro-tools-stdio.ts` (adapt from `fazm-tools-stdio.ts`) — wire to our existing DB via Unix socket callback
6. Implement Swift `ACPBridge.swift` + `NodeBinaryHelper.swift` + `BridgeSocketServer.swift`
7. Migrate existing 8 tools from `AgentCoordinator.swift` → `shiro-tools-stdio.ts`
8. Bundle Node.js runtime (~40MB) into `Resources/Node/bin/node`

**🎯 Exit criteria:**
- Floating bar message → Swift → stdio → Node bridge → tool call → Unix socket → Swift executes → response back up
- Existing functionality (chat, screen analysis, KG search) still works end-to-end
- `ps` shows parent Shiro.app + child node process

**Estimated time:** 8–12h

---

### 🚧 Phase 2 — Sub-Agent System (Shiro's edge over Fazm)
*Why next: sub-agents unblock everything else. Meeting mode, deep-research, ingestion all fan out via sub-agents.*

**Scope:**
1. `sub-agent-manager.ts` in Node bridge
   - SQL atomic checkout: `UPDATE tasks SET status='in_progress', claimed_by=? WHERE id=? AND status='todo' RETURNING *`
   - Persona library (`agent-personas.ts`): research-scout, code-finder, debugger, summarizer, planner, critic, action-item-extractor
   - Budget enforcement: max_depth=3, max_concurrent=3, max_iterations=10, token_budget=200K, timeout=5min
2. `Sources/Memory/TaskManager.swift` — state machine (backlog → todo → in_progress → done|cancelled), parent/child FK, `task_runs` audit table
3. New tool in shiro-tools: `spawn_sub_agent(personaId, mission, skillName?)` → returns sub_agent_id, streams status
4. New tool: `spawn_sub_agents_parallel(agents[])` → fan-out + await-all
5. Observer session — brain model can query running sub-agents via `get_sub_agent_status(id)`
6. `task_runs` row per run with full conversation archive → enables "interview any past run"

**🎯 Exit criteria:**
- Test: main agent issues `spawn_sub_agents_parallel` with 3 missions, all run concurrently, results return to main agent in parent task's final response
- Kill-one-sub-agent test: process or timeout kills a sub-agent → parent gets clean error → doesn't crash
- `task_runs` archive is queryable via `/interview <task_id>` slash command

**Estimated time:** 10–14h

---

### 🚧 Phase 3 — Local Vector RAG Stack
*Why next: your stated use cases (coding, RAG agents, fine-tuning, YouTube, learning) all need retrieval over your corpora. No more delaying this.*

**Scope:**
1. Add sqlite-vec extension loading to `Database.swift` (`pool.configuration.prepareDatabase { db in try db.loadExtension("vec0") }`)
2. Migration adding `rag_chunks`, `rag_chunks_vec`, `rag_chunks_fts`, `ingest_jobs`, `corpora` tables
3. `Sources/Memory/VectorStore.swift` — Swift wrapper over sqlite-vec queries
4. `Sources/Memory/RAGRetriever.swift` — hybrid: vector top-K + BM25 top-K → Reciprocal Rank Fusion → optional cross-encoder rerank
5. `Sources/Memory/Ingestor.swift` — pipeline: detect file type → route to chunker → embed → insert + FTS index → hash-based dedup
6. Chunkers: `CodeChunker` (tree-sitter via SwiftTreeSitter), `MarkdownChunker` (heading-hierarchy), `PDFChunker` (PDFKit + layout heuristics), `ProseChunker` (semantic boundary via embedding drift)
7. `CorpusManager.swift` — create/list/delete corpora, FSEvents auto-watch, embedding-model lock per corpus
8. Add to shiro-tools: `search_rag`, `ingest_document`, `ingest_url`, `list_corpora`, `create_corpus`, `ingest_status`
9. Seed default corpora: codebase, papers, clients, meetings, notes, screen-history, chat-history

**🎯 Exit criteria:**
- `ingest_document("~/Documents/Papers/attention-is-all-you-need.pdf", "papers")` → chunks appear in DB, FTS + vec indexes populated
- `search_rag("what is multi-head attention", corpus_id="papers")` returns relevant chunks from that paper in <200ms
- Hybrid retrieval beats pure-vector on precision in a 10-query manual test

**Estimated time:** 12–16h

---

### 🚧 Phase 4 — MCP Registry (Composio, GitHub, Context7, HF)
*Why next: unlocks your AI-eng / automation / freelance workflows without custom integration work.*

**Scope:**
1. `acp-bridge/src/mcp-registry.ts` — YAML loader, validator, env-var resolution (`${GITHUB_TOKEN}` syntax)
2. Replace Fazm's hardcoded `buildMcpServers()` with registry-driven spawning
3. `Sources/Bridge/MCPSupervisor.swift` — watches child MCP processes, auto-restart, health metrics → `mcp_health` table
4. Ship default `~/.shiro/mcp.yaml` with all bundled + commented-out optional servers
5. Per-skill MCP allow-listing: skill YAML → `allowed_mcp_tools: [github.create_pr, composio.gmail_draft]`
6. `/mcp` slash command: list connected, latency, error rate; `/mcp-install <name>` walkthrough
7. OAuth flow bridge for Composio: Swift opens browser → user auths → token callback → stored in Keychain
8. Wire the following in default config: `shiro_tools`, `playwright`, `macos-use`, `github`, `composio`, `context7`, `huggingface`, `filesystem`
9. Token storage: Keychain (never `.env` files for OAuth tokens)

**🎯 Exit criteria:**
- Agent calls `github.list_repos()` from a skill → works, cached, surfaces in `/mcp` status as healthy
- `composio.slack.send_message()` works after OAuth flow
- Crash an MCP child → supervisor restarts within 5s → tool calls resume

**Estimated time:** 8–10h

---

### 🚧 Phase 5 — Skills System + First 8 Skills
*Why next: skills are the UX surface. Without them, the agent is a raw REPL.*

**Scope:**
1. `acp-bridge/src/skill-dispatcher.ts` — load all `.skill.md` files (bundled + `~/.claude/skills/` + `~/.shiro/skills/`)
2. Parse YAML frontmatter: name, description, trigger_keywords, trigger_windows, allowed_tools, allowed_mcp_tools, requires_approval, persona
3. Match pipeline: slash command (explicit) → keyword scan → window title → default
4. `SkillInstaller.swift` — SHA-checksum sync, upgrade detection (fork Fazm's implementation verbatim — this is clean reusable code)
5. Swift `SkillsBrowser.swift` UI — list, enable/disable, install from URL
6. Ship 8 bundled skills (wave 1 per Section 16.8):
   - `capture-anything`, `ask-my-memory`, `daily-log`, `daily-standup` (common layer)
   - `commit-writer`, `deep-research`, `morning-briefing`, `handoff-writer` (core)

**🎯 Exit criteria:**
- Typing "commit" in the floating bar → `commit-writer` skill activates, reads staged diff, writes message
- All 8 skills return expected output in manual test
- User can drop new `.skill.md` in `~/.shiro/skills/` → hot-reloaded into dispatcher

**Estimated time:** 8–10h

---

### 🚧 Phase 6 — Hooks Engine + Slash Commands
**Scope:**
1. `Sources/Agent/HooksEngine.swift` — event emitter, subscriber pattern, settings.json loader
2. Event types: SessionStart/End, PreToolUse/PostToolUse, OnMeetingStart/End, OnStuckDetected, OnTaskCreate/Complete, OnNewFile/OnFileModified, OnSubAgentSpawn/Complete, OnScreenChange, OnApproval
3. Matcher syntax: tool-name glob, file glob, priority filter
4. `Sources/Agent/SlashCommandParser.swift` — lex `/cmd arg1 "quoted arg" --flag`
5. Built-in slash commands from Section 9
6. User-defined commands: `~/.shiro/commands/*.md` (same format as Claude Code)
7. `hooks_log` audit table
8. Settings UI in Swift for hooks + commands

**🎯 Exit criteria:**
- Configure a PostToolUse hook that logs every `write_file` → log file populates
- Type `/commit` → runs commit-writer skill
- User-defined `/standup` in `~/.shiro/commands/` → works

**Estimated time:** 6–8h

---

### 🚧 Phase 7 — Meeting Mode (the big one)
*Now we build it, because all primitives underneath are ready.*

**Scope:**
1. `Sources/Perception/MeetingDetector.swift` — window-title polling (Zoom/Meet/Teams/FaceTime) + manual `/meeting`
2. Meeting-mode skill full implementation (see Section 5)
3. Segment analyzer: sub-agent per final Deepgram segment, classifies: action_item | decision | question | info | off-topic
4. Action item extractor sub-agent (parallel with segment analyzer)
5. `Sources/UI/MeetingMode/MeetingOverlay.swift` — minimal recording indicator
6. `Sources/UI/MeetingMode/PostMeetingCard.swift` — approval gate with checkboxes
7. System audio capture via ScreenCaptureKit audio tap (macOS 13+) — mixed with mic
8. Markdown transcript export to `~/.shiro/meetings/`
9. Auto-ingest transcript into `meetings` corpus

**🎯 Exit criteria:**
- 15-min test meeting → overlay shows → action items extracted in real time → post-meeting card shows correctly → approve subset → tasks created
- Transcript searchable via `/ask-my-memory "what did we decide about X in the meeting with Y"`

**Estimated time:** 12–16h

---

### 🚧 Phase 8 — Autonomous Loops + Observer
**Scope:**
1. Morning briefing auto-fire at 9am (scheduled via shiro launchd agent)
2. Stuck detection (already partially done) → proactive suggestion overlay
3. File watcher → auto-ingest new files in configured paths
4. Meeting auto-detect + auto-activate (not manual)
5. Session snapshots for `/compact` and `/handoff`
6. Observer skill — background screen observation → summary insights into `screen-history` corpus
7. Evening review at 9pm

**🎯 Exit criteria:**
- Morning briefing fires at 9am, surfaces in floating bar
- Drop a PDF into `~/Documents/Papers/` → ingested + searchable within 60s
- 2-hour background session produces a usable evening summary

**Estimated time:** 6–8h

---

### 🚧 Phase 9 — Ollama + TTS + Always-On
**Scope:**
1. `ollama-proxy.ts` in Node bridge — Anthropic ↔ Ollama translation
2. Config flag to switch backends; test with llama3.3 or qwen2.5-coder
3. `Sources/Bridge/TTSService.swift` — AVSpeechSynthesizer primary + LM Studio qwen3-tts optional
4. VAD-based wake detection (not wake word — simpler) + push-to-talk global shortcut ⌘.
5. Response speaking with interruption (user speaks → TTS pauses)

**🎯 Exit criteria:**
- Switch backend to Ollama, run identical prompt, get comparable response
- ⌘. anywhere → floating bar listens → transcribes → responds via TTS
- Say anything while TTS speaking → TTS stops immediately

**Estimated time:** 6–8h

---

### 🚧 Phase 10 — Domain Skill Packs (incremental)
Per Section 16.8 sequencing:
- Wave 2: `ai-eng` pack (9 skills) — dogfood while building
- Wave 3: `creator` pack (9 skills)
- Wave 4: `automation` pack (8 skills)
- Wave 5: `learn` pack (7 skills)
- Wave 6: `work:freelance` (8 skills)
- Wave 7: `work:own-company` (8 skills)
- Wave 8: `life` pack (7 skills)
- Wave 9: `work:company` (6 skills)

Each wave = one focused session. Not all at once.

**Estimated time:** ~4h per wave × 8 waves = 32h

---

### 🚧 Phase 11 — Polish + Release
1. Knowledge graph visualizer (SwiftUI + force-directed layout)
2. Settings UI (models, hooks, skills, corpora, MCP servers, workspaces)
3. Onboarding flow (permissions: mic, screen, accessibility, FDA; API keys: Deepgram, GitHub, Composio, HF)
4. Launch agent (login item via ServiceManagement)
5. Menu bar presence
6. Global keyboard shortcuts
7. Crash reporter (local-only, not Sentry) + log viewer
8. App icon + app store bundle metadata
9. README, CONTRIBUTING, LICENSE
10. First public release tag v0.1.0

**Estimated time:** 10–14h

---

**Grand total estimate:** ~120–150h of focused build time. Delivered in 3–5 sessions per week × 8–12 weeks.

---

## 14. CTO Decisions — Made, Not Open

Earlier I listed 6 open decisions. As CTO I'm closing them now so we stop stalling. Change any if you disagree.

| # | Decision | Chosen | Why |
|---|----------|--------|-----|
| 1 | Ollama priority | **Phase 9, not Phase 1** | LM Studio covers all 4 current models. Ollama is a fallback, not a day-1 need. Shipping it early delays more valuable work. |
| 2 | MCP vs native tools | **MCP for everything external, native for OS-level** | Playwright/Composio/GitHub/Context7 via MCP. Native Swift for: accessibility, audio, screen, file, shell, calendar, notes. MCP via Node bridge (forked Fazm pattern). |
| 3 | TTS voice | **macOS AVSpeech default, LM Studio qwen3-tts optional toggle** | Fast by default, premium by choice. No dependency on LM Studio being up. |
| 4 | Always-listening default | **OFF. User flips ON per session.** | Privacy + battery. Default is push-to-talk (⌘.). |
| 5 | Wake word | **None in v1. Push-to-talk only.** | Porcupine adds a dependency + false-positive risk. ⌘. is universal, instant, deterministic. Wake word in v2 if requested. |
| 6 | Meeting audio source | **Both mic + system audio, mixed via ScreenCaptureKit audio tap (macOS 13+)** | Anything less loses half the conversation. Permission prompt is worth it. |
| 7 *(new)* | Agent runtime location | **Node/TS bridge (forked from Fazm), not Swift-only** | Gives us free Claude Sonnet integration via ACP SDK + cleaner MCP subprocess isolation. |
| 8 *(new)* | Vector store | **sqlite-vec in same SQLite file, not Qdrant/Chroma** | Zero extra process. File is portable. 300KB extension. We're not at a scale where ANN performance matters beyond this. |
| 9 *(new)* | License for Fazm-derived files | **Reimplement in our own source, don't file-copy. Open GitHub issue asking mediar-ai for explicit OSS license.** | Fazm README says "open source" but no LICENSE file. Patterns aren't copyrightable; files are. |
| 10 *(new)* | Repo + visibility | **Public GitHub repo `shiro` under user account. MIT license. Public README crediting Fazm, Paperclip, MiroFish, Claude Code.** | Open source aligns with user's YouTube/content strategy. Visibility = growth. |

---

## 15. Next Coding Session Plan

When you say "start Phase 1," this is the exact sequence:

1. **Session 1 (3–4h):** Phase 1 steps 1–5 — create `acp-bridge/`, fork Fazm files, wire minimal stdio echo loop.
2. **Session 2 (3–4h):** Phase 1 steps 6–8 — Swift ACPBridge, NodeBinaryHelper, Unix socket server, migrate 2 tools as proof.
3. **Session 3 (3–4h):** Phase 1 remainder — migrate remaining tools, delete direct LM Studio calls from AgentCoordinator, end-to-end test.
4. **Session 4 (4–5h):** Phase 2 start — SubAgentManager with atomic checkout, persona library, parallel spawn.
5. `/handoff` at the end of each.

---

## 16. Skill Packs by Use Case — Your Actual Daily Work

You listed six contexts you need Shiro to cover: **teaching, learning AI, YouTube creation, AI automation work, AI engineering, and daily usage — whether you're working for a company, freelancing, or building your own company.** This section maps each to concrete skill packs plus the "common features everywhere" layer that stays on regardless of context.

### 16.0 Common Layer — Always Available (mode-agnostic)

These skills stay loaded no matter which context you're in. They're your Jarvis core:

| Skill | What It Does |
|-------|--------------|
| `capture-anything` | ⌘⇧C anywhere → Shiro grabs current screen + clipboard + selection → files it into KG with auto-tags |
| `ask-my-memory` | Ask any natural-language question → semantic search across KG + files + past meetings + screen history |
| `time-tracker` | Passive app/window tracking → daily time breakdown per project → shown on request, never pushed |
| `daily-log` | Auto-compile what you did today from git commits + meetings + screen observations → saved to `~/.shiro/journal/YYYY-MM-DD.md` |
| `focus-mode` | `/focus 90min <goal>` → blocks Slack/mail notifications, starts Pomodoro, reminds you at end |
| `quick-capture` | Voice or text note → classified into the right domain pack → saved to right place |
| `ask-the-web` | DDG / SearXNG search with result summarization |
| `daily-standup` | `/standup` → reads yesterday's commits + today's calendar + open tasks → drafts "Yesterday / Today / Blockers" |

### 16.1 Skill Pack: **`learn`** — Teaching & Learning AI

*Use when: reading papers, watching lectures, taking Coursera/DeepLearning.AI courses, exploring new frameworks.*

| Skill | Trigger | What It Does |
|-------|---------|--------------|
| `study-mode` | `/study <topic>` or window = PDF/Coursera | Active-reading loop: you highlight text → Shiro quizzes you on it → spaced-repetition deck generated |
| `paper-reader` | drop PDF into chat OR `/paper <arxiv-id>` | Fetches paper → extracts: problem, method, results, limitations → stores each as KG nodes linked to the paper → 5 follow-up questions |
| `concept-mapper` | auto-fires during study-mode | Every new term becomes a KG node. Auto-links to prerequisites. Detects "you don't know X yet but X is needed for Y." |
| `flashcard-maker` | `/flashcards <topic>` | Pulls KG nodes for topic → generates Anki-format cards → exports .apkg or JSON |
| `explain-like-im-5` | `/eli5 <concept>` | Progressive explanation: 5 → 15 → 25 year old → expert — stops at the level where you nod |
| `lecture-mode` | detects YouTube/video + `/lecture on` | Streams captions, flags key claims, pauses on your command with ⌘. → inserts question/note into timestamped log |
| `code-along` | detects terminal + tutorial open | Watches what the tutorial shows vs what you typed → flags deviations → "step 4 says `pip install transformers`, you installed `transformer`" |

**Integration points:** KG stores everything as `concept` / `paper` / `lecture` nodes with `prerequisite_of` / `variant_of` / `implements` edges. When you revisit a topic in 3 weeks, Shiro pulls your full prior context.

### 16.2 Skill Pack: **`creator`** — YouTube / Content Creation

*Use when: planning videos, recording, editing, writing scripts, thumbnails, shorts.*

| Skill | Trigger | What It Does |
|-------|---------|--------------|
| `video-idea-vault` | `/idea <text>` or KG detects "good video topic" phrase | Adds to `video_ideas` KG bucket with tags, competitor coverage (sub-agent search), audience-fit score |
| `script-writer` | `/script <topic>` | Drafts YouTube script in your voice (KG learns your style from past scripts). Hooks, main beats, CTA. Saves as markdown. |
| `hook-tester` | `/hooks <topic>` | Generates 10 opening hooks → ranks by curiosity-gap heuristics → you pick one |
| `thumbnail-planner` | `/thumb <video-title>` | Describes 3 thumbnail concepts with composition, color palette, text overlay; optionally calls local SD/Flux for drafts |
| `shorts-extractor` | `/shorts <video.mp4>` | Reads transcript → picks 3 high-retention 30-60s clips → exports timestamps + suggested captions |
| `title-ab-lab` | `/titles <topic>` | Generates 12 title variants ranked by CTR heuristics (curiosity, number, specificity) |
| `description-writer` | `/desc <script.md>` | Writes SEO-tuned description + timestamps + hashtags |
| `content-calendar` | `/calendar` | Pulls video ideas + scripts in progress + filmed-not-edited → weekly cadence view |
| `competitor-watch` | weekly hook | Deep-research sub-agent surveys 5 channels you specify → "these 3 topics are trending, you haven't covered" |

**Integration points:** Uses Playwright MCP for YouTube Studio scraping (optional). KG stores your channel's topic graph → suggests content gaps.

### 16.3 Skill Pack: **`automation`** — AI Automation (n8n, Vapi, webhooks)

*Use when: building client automations, voice agents, workflow integrations.*

| Skill | Trigger | What It Does |
|-------|---------|--------------|
| `workflow-designer` | `/flow <goal>` | Given a goal ("Slack → summarize → email"), drafts n8n node structure, lists creds needed, writes JSON skeleton |
| `n8n-node-lookup` | `/n8n <node-name>` | Pulls current n8n docs via context7 or WebFetch → returns config schema + examples |
| `webhook-inspector` | `/webhook listen <port>` | Spawns local http listener → pretty-prints incoming payloads + copy-as-schema |
| `api-tester` | `/api <curl>` | Parses curl, runs, formats response, suggests retry/rate-limit handling |
| `vapi-agent-builder` | `/vapi <use-case>` | Scaffolds Vapi assistant config: voice, model, first message, function calls, knowledge base setup |
| `prompt-for-agent` | `/promptify <flow-desc>` | Writes system prompt tuned for agent use cases (tool-calling, JSON output, edge handling) |
| `cred-vault-check` | PreToolUse | Before any automation deploy: verifies expected env vars / OAuth creds are present — warns if missing |
| `deploy-checklist` | `/deploy <project>` | Runs a pre-flight: env vars set? webhooks reachable? rate limits known? error handling present? → red/green list |

**Integration points:** Context7 MCP for fresh docs. Playwright MCP for clicking through n8n UI if needed. KG stores client configs (encrypted).

### 16.4 Skill Pack: **`ai-eng`** — AI Engineering (RAG, Agents, Embeddings, Vector DBs)

*Use when: building RAG systems, fine-tuning, evaluating models, shipping inference.*

| Skill | Trigger | What It Does |
|-------|---------|--------------|
| `rag-builder` | `/rag <corpus-path>` | Walks you through: chunking strategy → embedding model pick → vector store pick → retrieval eval. Generates full scaffold. |
| `prompt-tester` | `/ptest <prompt.yaml>` | Runs prompt across N cases in parallel against both local model + API. Diff output. |
| `embedding-bench` | `/embed-bench <corpus>` | Tests 3 embedding models on retrieval quality: MTEB-style mini-eval → reports recall@5, latency, $/1M tokens |
| `chunk-strategist` | `/chunk <file>` | Previews 4 chunking strategies (fixed, semantic, markdown-aware, hierarchical) side-by-side on your file |
| `vector-db-compare` | `/vdb` | Quick comparison: Qdrant / Chroma / Weaviate / pgvector for your scale + budget |
| `agent-trace-reader` | drops LangSmith/Langfuse trace | Reads trace → explains why agent failed → suggests prompt/tool fix |
| `eval-set-builder` | `/evals <capability>` | Generates 30-50 test cases for a capability (extractive QA, classification, etc.) with expected outputs |
| `inference-cost-calc` | `/cost-calc <scenario>` | Given volume + model choice → returns monthly spend across OpenAI / Anthropic / local / mix |
| `fine-tune-plan` | `/ft <problem>` | Decides: do you even need fine-tuning? LoRA vs full? SFT vs DPO? Which dataset? Cost estimate. |

**Integration points:** LM Studio for local runs. Context7 for latest LangChain/LlamaIndex/DSPy docs. Shell tool for running evals.

### 16.5 Skill Pack: **`work`** — Job Context Switcher

*Use when: you're doing paid work. Shiro needs to know WHICH context so it pulls the right KG slice, applies the right voice, and keeps records clean.*

Your three work contexts share the same underlying skills but differ in **memory scope, tone, and approvals**. Shiro supports all three simultaneously via a `workspace` tag on every task/note/meeting.

#### 16.5a `workspace:company` — Employed / Full-time Role
| Skill | What It Does |
|-------|--------------|
| `standup-drafter` | Auto-compiles daily standup from git + meetings + tasks |
| `sprint-syncer` | Reads Jira/Linear/Asana (via MCP or API) → reconciles against local tasks |
| `manager-1on1-prep` | Night before 1:1 → compiles: wins this week, blockers, asks, growth topics |
| `doc-writer` | Writes PRDs / design docs in company voice (learns from examples you paste) |
| `pto-tracker` | Knows when you're off → auto-snoozes pings during PTO |
| `compliance-guard` | PreToolUse: never lets company IP leak into personal workspace files |

#### 16.5b `workspace:freelance` — Client Work (US / Canada / Australia / NZ)
| Skill | What It Does |
|-------|--------------|
| `client-brief-writer` | `/brief <client>` → pulls meeting transcripts + slack threads → drafts scope doc |
| `invoice-drafter` | End of month: compiles billable hours per client (from time-tracker) → drafts invoice PDF |
| `client-followup` | Detects "I'll send you X by Y" in meetings → tracks → reminds you day before due |
| `timezone-buddy` | Always shows current time in client TZ when their name is in context |
| `proposal-writer` | `/proposal <project>` → scope, deliverables, timeline, price → in your voice |
| `msa-reader` | Drop contract PDF → extracts key clauses: IP ownership, payment terms, termination, liability → flags risks |
| `scope-creep-alarm` | Detects when a new client request is out of agreed scope → drafts polite "this is out of scope, here's the change order" |
| `retainer-tracker` | For retainer clients: tracks hours consumed vs contracted, warns at 80% |

#### 16.5c `workspace:own-company` — Building Your Own Company
| Skill | What It Does |
|-------|--------------|
| `founder-log` | Daily: what moved the needle, what didn't, decisions made — saved to a private founder journal |
| `customer-interview-analyzer` | Drop interview transcript → extracts: pain points, language used, willingness to pay, objections |
| `landing-page-critic` | `/critique <url>` → screenshots page → critiques: clarity of value prop, CTA strength, trust signals |
| `pricing-strategist` | `/pricing <product>` → guides you through value-based pricing with competitor survey |
| `hire-screener` | Drop a resume → matches against JD, flags strengths/gaps, drafts first-round questions |
| `roadmap-planner` | `/roadmap` → given current goals + user interviews + constraints → proposes next 3 months |
| `investor-update` | Monthly: compile MRR / users / wins / asks → drafts investor update email |
| `product-metric-tracker` | Pulls from PostHog/Plausible/Mixpanel → daily KPIs → trend flags |

### 16.6 Skill Pack: **`life`** — Daily Life / Personal Ops

*Common features regardless of work mode — your personal Jarvis layer.*

| Skill | What It Does |
|-------|--------------|
| `morning-briefing` | 9am: weather, calendar, top 3 tasks, overnight news in your domains |
| `evening-review` | 9pm: "here's what you did today / what's tomorrow / any unresolved decisions?" |
| `birthday-radar` | Pulls contacts → reminds 3 days before birthdays of people you care about (KG tag: `close`) |
| `health-nudge` | Noticed you've been heads-down 4 hours → "stand up, drink water" (configurable intensity) |
| `decision-journal` | `/decide <question>` → guided prompts → saves decision + reasoning → pings you 2 weeks later to review |
| `gratitude-capture` | Passing mention of something good → saves to gratitude log → weekly summary |
| `read-later` | Sends any URL to Shiro → summary + KG ingestion + retrievable by topic later |

### 16.7 How Skill Packs Compose

Packs aren't walls — they overlap. A meeting during `workspace:freelance` activates: `meeting-mode` (core) + `client-followup` (freelance) + `time-tracker` (common) all at once. The active skill list is always: `core + current-workspace-pack + any-triggered-packs`.

**Switching workspaces:** `/workspace company|freelance|own|personal` OR auto-detected from window title (git repo path matches a known workspace map in `~/.shiro/workspaces.yaml`).

**Memory isolation:** KG nodes are tagged with `workspace`. `ask-my-memory` defaults to current workspace but can be widened with `--all`.

### 16.8 Build Sequencing for Skill Packs

Packs ship after the core is solid. Proposed order (slots into Phase 4 of the build plan):

1. **First wave (Phase 4a):** `meeting-mode`, `commit-writer`, `deep-research`, `morning-briefing`, `capture-anything`, `ask-my-memory` — prove the format works.
2. **Second wave (Phase 4b):** pick the ONE pack you want next. My recommendation: **`ai-eng`** — because you'll use it while building Shiro itself, creating a useful feedback loop. Second best: **`creator`** if YouTube is the monetization play.
3. **Later waves:** `automation` → `learn` → `work:freelance` → `work:own-company` → `life` → `work:company`.

You don't need all 60+ skills on day one. You need the 6 in wave 1 + the 8-9 in one pack to prove the pattern, then iterate.

---

## 17. Per-Component Deep Spec — Implementation Reference

*Every major module gets the same 5-field template. This is the contract any future Claude/LLM/human must follow when building or editing that module.*

**Template:**
```
▸ Purpose        — one sentence, why this exists
▸ Contract       — inputs, outputs, public API (signatures)
▸ State/Data     — what it owns, schemas, files touched
▸ Implementation — step-by-step build approach
▸ Verify         — how to prove it works
```

---

### 17.1 `ACPBridge.swift` (Swift)

```
▸ Purpose
  Spawns and manages the Node bridge subprocess. Owns stdin/stdout framing,
  lifecycle (start/stop/restart), crash recovery, ready signal.

▸ Contract
  public actor ACPBridge {
    func start() async throws
    func stop() async
    func send(_ message: BridgeMessage) async throws
    var incoming: AsyncStream<BridgeMessage> { get }
    var status: BridgeStatus { get }  // .stopped|.starting|.ready|.crashed(Error)
  }

▸ State/Data
  - Owns Process handle + Pipes
  - JSONL framing: one message per line, \n-delimited
  - Maintains pending-request table keyed by request_id (for response correlation)
  - Logs all I/O to ~/Library/Logs/Shiro/bridge.log with rotation

▸ Implementation
  1. Fork Fazm's Chat/ACPBridge.swift + NodeBinaryHelper.swift
  2. Swap executable path: bundled Node at Resources/Node/bin/node
  3. Change entrypoint: ./acp-bridge/dist/index.js
  4. Remove Fazm-account env vars, add SHIRO_DB_PATH, SHIRO_BRIDGE_SOCKET
  5. Auto-restart on exit (exponential backoff, max 3 tries, then surface error)
  6. Emit status transitions to AppState

▸ Verify
  - Unit test: start bridge → send ping → receive pong within 1s
  - Manual test: kill node pid → bridge auto-restarts → status goes ready again
  - Log inspection: every send/receive appears in bridge.log
```

---

### 17.2 `shiro-tools-stdio.ts` (Node bridge)

```
▸ Purpose
  MCP server (stdio transport) exposing all app-level tools to the agent.
  Calls back into Swift via Unix domain socket for DB, capture, filesystem, etc.

▸ Contract (MCP tools exposed)
  execute_sql(query, params?)       → rows
  capture_screenshot(displayId?)    → { path, width, height, timestamp }
  read_file(path)                   → { content, encoding }
  write_file(path, content, mode?)  → { ok, bytes_written }
  search_kg(query, top_k?)          → nodes[]
  search_rag(query, corpus_id?, top_k?, rerank?) → chunks[]
  ingest_document(path, corpus_id)  → ingest_job_id
  create_task(title, description?, parent_id?, priority?) → task_id
  spawn_sub_agent(persona, mission, skill?) → sub_agent_id
  spawn_sub_agents_parallel(agents[]) → sub_agent_ids[]
  get_sub_agent_status(id)          → { status, iterations, result? }
  speak_response(text, voice?)      → ok
  check_permission(type)            → granted|denied
  get_screen_context()              → { app, window_title, analysis }
  save_kg_node(name, type, summary, attrs?) → node_id
  add_kg_edge(from, to, relationship, fact?) → edge_id
  get_time()                        → iso_string
  get_active_app()                  → { name, pid, window_title }

▸ State/Data
  - Connects to Unix socket at $SHIRO_BRIDGE_SOCKET
  - Each tool call → JSON request over socket → Swift handles → JSON response back
  - No local state; stateless wrapper

▸ Implementation
  1. Fork fazm-tools-stdio.ts structure
  2. Implement each tool as a { name, description, input_schema, handler } object
  3. handler = async (args) => callSwift(tool_name, args)
  4. Session filtering: ONBOARDING_TOOLS, MAIN_TOOLS, OBSERVER_TOOLS, MEETING_TOOLS,
     SUBAGENT_TOOLS — each a subset passed to the ACP runtime for that session
  5. MCP init: register with @modelcontextprotocol/sdk as stdio server

▸ Verify
  - Run bridge standalone with node dist/acp-bridge.js
  - Use MCP Inspector (npx @modelcontextprotocol/inspector) to enumerate tools
  - Call each tool manually, verify Swift side logs the call
```

---

### 17.3 `sub-agent-manager.ts` (Node bridge) — THE key module

```
▸ Purpose
  Manages parallel sub-agent lifecycle with atomic task checkout,
  persona injection, budget enforcement. This is Shiro's edge over Fazm.

▸ Contract
  export class SubAgentManager {
    async spawn(opts: SpawnOptions): Promise<SubAgent>
    async spawnParallel(opts: SpawnOptions[]): Promise<SubAgent[]>
    async awaitAll(ids: string[]): Promise<SubAgentResult[]>
    async kill(id: string, reason: string): Promise<void>
    getStatus(id: string): SubAgentStatus
    onStatusChange: EventEmitter
  }
  interface SpawnOptions {
    persona: PersonaId
    mission: string
    parent_task_id?: string
    skill?: string
    max_iterations?: number
    timeout_ms?: number
    token_budget?: number
    allowed_tools?: string[]
  }

▸ State/Data
  - tasks table (parent_task_id, status, claimed_by, token_count, started_at, ended_at)
  - task_runs table (id, task_id, conversation_json, tool_calls_json, final_result, total_tokens)
  - In-memory Map<sub_agent_id, AgentRuntimeHandle>
  - Global counters: active_count, total_depth_seen
  - Enforcement limits (from config):
      max_concurrent = 3
      max_depth = 3
      max_iterations_per_agent = 10
      token_budget_per_run = 200_000
      timeout_ms = 300_000

▸ Implementation
  1. Atomic checkout SQL:
       UPDATE tasks
       SET status='in_progress', claimed_by=?, started_at=now()
       WHERE id=? AND status='todo'
       RETURNING *
     Fail-if-zero-rows → double-claim prevented.
  2. For each sub-agent: create new ACP session with:
       - persona system prompt (from agent-personas.ts)
       - tool filter = allowed_tools ∩ SUBAGENT_TOOLS ∩ skill.allowed_tools
       - depth-decremented (current_depth + 1)
       - parent_task context injected
  3. Use Promise.all() for parallel execution; LM Studio queues naturally
  4. Per-agent monitor: interval check token count, iteration count, wall clock
  5. Budget breach → graceful stop + status='cancelled' + error msg to parent
  6. On completion: write final_result to task, fire onStatusChange('done'), return
  7. Hooks: emit OnSubAgentSpawn / OnSubAgentComplete events

▸ Verify
  - Unit test (sqlite in-memory): 10 concurrent spawn() calls, verify only max_concurrent run at once
  - Integration test: parent task with 3 parallel children, all complete, result assembled
  - Kill test: spawn agent, kill mid-run, verify cleanup + status='cancelled'
  - Budget test: agent with token_budget=100, verify stops on iteration 1 if iter > budget
  - Depth test: depth-3 chain works, depth-4 attempt rejected with clear error
```

---

### 17.4 `VectorStore.swift` (Swift)

```
▸ Purpose
  Thin wrapper over sqlite-vec for insert, delete, vector search.
  NOT the retriever — pure vector operations only.

▸ Contract
  public struct VectorStore {
    init(database: ShiroDatabase)
    func insert(chunkId: String, embedding: [Float]) async throws
    func delete(chunkId: String) async throws
    func nearest(to query: [Float], topK: Int, filter: Filter?) async throws -> [VectorHit]
    func nearestInCorpus(to query: [Float], corpusId: String, topK: Int) async throws -> [VectorHit]
  }
  struct VectorHit { let chunkId: String; let distance: Float }

▸ State/Data
  - Reads/writes rag_chunks_vec virtual table (sqlite-vec vec0)
  - Cosine distance by default; MATCH operator
  - No caching — rely on SQLite page cache

▸ Implementation
  1. In Database.swift, on DB open:
       pool.configuration.prepareDatabase { db in
         try db.loadExtension("vec0")
       }
  2. Migration adds: CREATE VIRTUAL TABLE rag_chunks_vec USING vec0(
       chunk_id TEXT PRIMARY KEY,
       embedding FLOAT[768]
     )
  3. insert: INSERT INTO rag_chunks_vec(chunk_id, embedding) VALUES (?, ?)
     (sqlite-vec accepts float32 blob from Swift via SQLExpressible bridging)
  4. nearest: SELECT chunk_id, distance FROM rag_chunks_vec
             WHERE embedding MATCH ? ORDER BY distance LIMIT ?
  5. Filter variant joins rag_chunks table for metadata filters

▸ Verify
  - Insert 1000 synthetic vectors, query nearest → returns top-K sorted
  - Benchmark: p50 latency on 100K vectors < 50ms
  - Delete test: insert then delete → nearest no longer returns it
```

---

### 17.5 `RAGRetriever.swift` (Swift)

```
▸ Purpose
  Hybrid retrieval combining vector ANN + BM25 via Reciprocal Rank Fusion (RRF),
  optional cross-encoder rerank. Returns ranked chunks with metadata.

▸ Contract
  public actor RAGRetriever {
    init(db: ShiroDatabase, vectorStore: VectorStore, embedder: Embedder)
    func search(
      query: String,
      corpusIds: [String]? = nil,
      workspace: String? = nil,
      topK: Int = 8,
      rerank: Bool = false
    ) async throws -> [RetrievalResult]
  }
  struct RetrievalResult {
    let chunk: RAGChunk
    let scores: (vector: Float, bm25: Float, rrf: Float, rerank: Float?)
  }

▸ State/Data
  - Reads: rag_chunks, rag_chunks_vec, rag_chunks_fts
  - No writes
  - Depends on Embedder (LM Studio) for query embedding

▸ Implementation
  1. Parallel:
       a. Embed query → VectorStore.nearest(topK: 20, filter by corpora+workspace)
       b. FTS5 query: SELECT rowid, bm25(rag_chunks_fts) FROM rag_chunks_fts
                      WHERE rag_chunks_fts MATCH ? LIMIT 20
  2. Merge via RRF: score = Σ 1/(k + rank_i), k=60
  3. Top topK by RRF score
  4. If rerank=true: build (query, chunk) pairs → call fast model with scoring prompt →
     sort by rerank score
  5. Fetch full RAGChunk rows for IDs, return with scores

▸ Verify
  - Unit test: hybrid beats pure-vector on 10 synthetic queries (precision@5)
  - Latency: end-to-end < 300ms on 50K-chunk corpus
  - Manual: ingest Attention paper, query "multi-head attention", top-1 is the right section
```

---

### 17.6 `Ingestor.swift` + `Chunkers/*` (Swift)

```
▸ Purpose
  End-to-end pipeline: detect file type → route to chunker → embed chunks →
  insert rag_chunks + rag_chunks_vec + rag_chunks_fts → track job status.

▸ Contract
  public actor Ingestor {
    func ingest(path: URL, corpusId: String, metadata: [String:Any] = [:]) async throws -> String  // job_id
    func ingestURL(_ url: URL, corpusId: String) async throws -> String
    func status(jobId: String) async throws -> IngestStatus
    func cancel(jobId: String) async throws
  }

▸ State/Data
  - ingest_jobs table (id, corpus_id, source_path, status, chunks_total, chunks_processed, error, timestamps)
  - Writes to rag_chunks, rag_chunks_vec, rag_chunks_fts
  - Dedup key: SHA256(chunk.content) → skip if exists in same corpus

▸ Implementation (per chunker)
  CodeChunker:
    - Use SwiftTreeSitter language grammars (ts-python, ts-ts, ts-swift, ts-go, ts-rust)
    - Walk AST, emit one chunk per function + one per class/struct
    - Include surrounding imports in metadata
    - Fall back to 400-line sliding window if language unsupported

  MarkdownChunker:
    - Parse via swift-markdown
    - One chunk per H2 section (or H1 if H2 absent); include heading path in metadata
    - Max chunk size 1500 tokens; split long sections at paragraph boundaries

  PDFChunker:
    - Extract text via PDFKit
    - Detect headings by font size heuristic
    - One chunk per section; include page numbers in metadata

  ProseChunker:
    - Semantic boundary: embed sliding 400-token windows, detect drift > threshold
    - Fall back to paragraph + fixed 400 token targets

▸ Verify
  - Ingest Shiro's own source code → chunks contain full functions
  - Ingest 5-page markdown → one chunk per H2, headings preserved in metadata
  - Ingest Attention PDF → correct section boundaries, page numbers accurate
  - Dedup: ingest same file twice → second run reports 0 new chunks
  - Cancel: start big ingest, cancel mid-way → partial chunks preserved, status='cancelled'
```

---

### 17.7 `MCPRegistry` + `MCPSupervisor.swift`

```
▸ Purpose
  Declarative MCP server registry. Supervises child MCP processes.
  Health metrics, crash auto-restart, per-skill allow-listing.

▸ Contract (Swift MCPSupervisor)
  public actor MCPSupervisor {
    func loadRegistry(from yamlPath: URL) async throws
    func startAll() async throws
    func stop(serverName: String) async
    func restart(serverName: String) async throws
    var health: [String: ServerHealth] { get }
    func toolsEnabledForSession(_ session: SessionKind) -> [MCPToolRef]
  }

▸ State/Data
  - ~/.shiro/mcp.yaml (canonical source of truth)
  - mcp_health table (server_name, status, last_restart, tool_call_count, p50_latency_ms, error_rate)
  - Keychain items for OAuth tokens (never .env for tokens)

▸ Implementation
  1. Node side (mcp-registry.ts):
       - Load yaml, resolve ${ENV_VARS}, validate schema (zod)
       - For each enabled: spawn child via @modelcontextprotocol/sdk StdioClientTransport
       - Aggregate discovered tools into single MCPToolset, tag by server name
  2. Swift side (MCPSupervisor):
       - Monitors bridge logs for MCP child PIDs
       - On crash: tell bridge to restart-server(name) via socket
       - Exponential backoff: 1s, 2s, 4s, 8s → give up after 4 tries
  3. OAuth flow (Composio):
       - User clicks "Connect Composio" in settings
       - Swift opens browser to Composio OAuth URL
       - Composio redirects to shiro://oauth-callback?code=...
       - Swift registers as URL scheme handler, intercepts code
       - Token stored in Keychain, env var exposed to bridge on next start

▸ Verify
  - Default mcp.yaml loads, all bundled servers spin up
  - Simulate crash: kill github-mcp child → supervisor restarts within 5s
  - Tool discovery: agent can call github.list_repos after auth
  - Skill filter: commit-writer skill only sees allowed tools, not all 250 Composio tools
```

---

### 17.8 `SkillRegistry` + `SkillDispatcher`

```
▸ Purpose
  Discover, parse, match, and dispatch .skill.md files.
  Skills are the primary UX surface.

▸ Contract
  public actor SkillRegistry {
    func loadAll() async throws
    func match(query: String, windowTitle: String, slashCommand: String?) -> Skill?
    func register(_ skill: Skill)
    func unregister(id: String)
    var all: [Skill] { get }
  }
  struct Skill {
    let id: String
    let name: String
    let description: String
    let triggerKeywords: [String]
    let triggerWindows: [String]
    let allowedTools: [String]
    let allowedMCPTools: [String]
    let requiresApproval: [String]
    let persona: String?
    let systemPrompt: String  // body of .skill.md
    let source: URL           // filesystem path
    let sha256: String
  }

▸ State/Data
  - skills_installed table (name, sha256, enabled, path, installed_at)
  - Reads:
      Bundle/Resources/BundledSkills/*.skill.md
      ~/.claude/skills/**/*.skill.md (shared with Claude Code!)
      ~/.shiro/skills/**/*.skill.md
  - FSEvents watch on user skill dirs for hot-reload

▸ Implementation
  1. .skill.md parser: split YAML frontmatter (between --- markers) from body
  2. yaml decoder → Skill struct (use Yams library)
  3. SHA256 body → sha256 field → use for installer update detection
  4. Match algorithm:
       a. If slashCommand non-nil: exact match on skill.id or skill.name
       b. Scan query lowercased for any skill.triggerKeywords
       c. Match windowTitle against skill.triggerWindows patterns
       d. Score = keyword_matches * 2 + window_match * 3
       e. Return highest-scored, or nil if no matches
  5. Dispatch: selected skill's systemPrompt becomes the session's system message;
     allowedTools ∩ registered MCP tools = session toolset

▸ Verify
  - Load 8 bundled skills at startup, skills_installed table shows all
  - Type "commit" → commit-writer skill selected
  - Open Zoom Meeting window → meeting-mode selected automatically
  - Edit a skill file → FSEvents → registry reloads within 1s
  - SHA mismatch between bundled and installed → installer upgrades
```

---

### 17.9 `TaskManager.swift`

```
▸ Purpose
  Task state machine with atomic checkout, parent/child relationships,
  approval gates. This is the Paperclip pattern.

▸ Contract
  public actor TaskManager {
    func create(title: String, description: String?, parentId: String?, priority: Priority) async throws -> Task
    func claim(taskId: String, claimedBy: String) async throws -> Task?   // nil if already claimed
    func complete(taskId: String, result: String) async throws
    func cancel(taskId: String, reason: String) async throws
    func list(status: TaskStatus?, workspace: String?) async throws -> [Task]
    func subtree(rootId: String) async throws -> TaskTree
    func interview(taskId: String) async throws -> TaskRun  // full conversation archive
  }
  enum TaskStatus { case backlog, todo, inProgress, done, cancelled, needsApproval }

▸ State/Data
  - tasks table (id, title, description, status, priority, parent_id, workspace,
                 claimed_by, result, created_at, updated_at)
  - task_runs table (id, task_id, conversation_json, tool_calls_json, total_tokens,
                     started_at, completed_at)
  - approvals table (id, task_id, action_type, payload_json, status, resolved_at)

▸ Implementation
  1. create: INSERT with status='backlog' (or 'todo' if immediately actionable)
  2. claim: SQL UPDATE ... WHERE id=? AND status='todo' RETURNING *; nil if no rows
  3. complete: UPDATE status='done', result=?, updated_at=now()
  4. cancel: UPDATE status='cancelled', result=reason
  5. Parent-completion check: on child completion, if all siblings done → emit
     OnAllChildrenComplete event (hooks can fire, parent agent can wake up)
  6. Approval gate: if action in skill.requiresApproval → create approval row,
     status='needsApproval', pause, wait for user approval notification

▸ Verify
  - Concurrent claim: 10 goroutines race on one task, only one succeeds
  - Parent/child: create root + 3 children, complete all → tree returns correct shape
  - Approval: spawn task with send_email → approval row created → user approves →
     task resumes → email sent; user rejects → task status='cancelled'
  - Interview: complete task → query task_runs[task_id] → full conversation returned
```

---

### 17.10 `HooksEngine.swift` + `SlashCommandParser.swift`

```
▸ Purpose
  Event-driven automation + command parser. Claude Code pattern.

▸ Contract (HooksEngine)
  public actor HooksEngine {
    func load(from path: URL) async throws     // ~/.shiro/settings.json
    func emit(_ event: ShiroEvent, data: [String: Any]) async
    func register(event: ShiroEventType, handler: Handler)
  }
  enum ShiroEventType: String {
    case sessionStart, sessionEnd
    case preToolUse, postToolUse
    case onMeetingStart, onMeetingEnd
    case onStuckDetected
    case onTaskCreate, onTaskComplete
    case onNewFile, onFileModified
    case onSubAgentSpawn, onSubAgentComplete
    case onScreenChange
    case onApproval
  }

  Slash commands:
  public struct SlashCommand {
    let name: String
    let args: [String]
    let flags: [String: String]
  }
  public func parseSlash(_ input: String) -> SlashCommand?

▸ State/Data
  - ~/.shiro/settings.json (hook configs)
  - hooks_log table (event, hook_command, exit_code, output, triggered_at)

▸ Implementation
  1. Load JSON → validate → register each { event, matcher, command, blocking } entry
  2. emit(event, data):
       - Filter matchers (glob on tool name, file path, priority)
       - Run shell command with data piped as JSON on stdin
       - If blocking=true: wait for exit, non-zero → block the triggering action
       - Log every run to hooks_log
  3. Slash parser: tokenize by whitespace respecting quotes; split first token from rest;
     recognize --flag=value and --flag value
  4. Built-in commands dispatch:
       /meeting → activate meeting-mode
       /task <desc> → TaskManager.create
       /sub <mission> → spawn one sub-agent
       /kg <topic> → KG search
       /handoff → trigger handoff-writer skill
       /compact → session snapshot
       /status → bridge + MCP health
       /interview <taskId> → TaskManager.interview

▸ Verify
  - Configure PostToolUse hook logging write_file → call write_file → log file appears
  - Slash parse: `/task "fix the bug" --priority=high` → correct SlashCommand struct
  - User-defined ~/.shiro/commands/foo.md → /foo works
  - Blocking hook returns non-zero → tool call aborted, user notified
```

---

### 17.11 `MeetingDetector` + `MeetingManager`

```
▸ Purpose
  Auto-detect meeting windows, orchestrate meeting-mode skill, capture mixed audio.

▸ Contract
  public actor MeetingManager {
    func start(source: MeetingSource) async throws -> MeetingSession
    func stop() async throws
    var currentSession: MeetingSession? { get }
    var onSegment: AsyncStream<Segment> { get }
    var onAction: AsyncStream<ActionItem> { get }
  }
  enum MeetingSource { case auto, manual, scheduled(CalendarEvent) }

▸ State/Data
  - meeting_sessions table (id, started_at, ended_at, source, window_title,
                            attendees_json, summary, transcript_path)
  - meetings corpus in RAG store (each session's transcript chunked+ingested)
  - ~/.shiro/meetings/YYYY-MM-DD-HHMM-slug.md (markdown export)

▸ Implementation
  1. MeetingDetector: poll NSWorkspace.shared.frontmostApplication window title
     every 3s; match patterns: /Zoom Meeting|Google Meet|Microsoft Teams|FaceTime/
  2. On detect: call MeetingManager.start(.auto)
  3. start():
       - Query calendar for matching event (EventKit), extract attendees/title
       - Insert meeting_sessions row
       - Start Deepgram streaming (mic + system audio mixed via ScreenCaptureKit audio)
       - Spawn observer sub-agent: listens to onSegment, classifies each
       - Spawn action-item-extractor sub-agent: parallel, consumes action candidates
       - Show MeetingOverlay UI
  4. Mixed audio: create AVAudioMixerNode, connect mic + SCStream audio output →
     downsample to 16kHz mono → frame to Deepgram
  5. stop():
       - Final transcript to brain model for synthesis
       - Show PostMeetingCard with approval gate per action item
       - Write markdown transcript
       - Ingest into meetings corpus
       - KG extraction: attendees, projects, commitments

▸ Verify
  - Open Zoom → detector fires → overlay appears within 3s
  - 15-min test meeting: 3 speakers, clear speech → transcript accuracy > 90%
  - Action items extracted in real-time, visible during meeting
  - Post-meeting card shows correct items, approval gates work
  - Transcript searchable in meetings corpus afterwards
```

---

### 17.12 UI Components (deferred — "we'll talk later")

*User asked to defer UI details. Placeholder: existing FloatingBarView.swift stays as the seed, other surfaces (TaskBoard, MeetingMode, GraphViewer, SkillsBrowser, Settings) get their own mini-spec in a future UI-focused session.*

---

## 18. Inspiration Appendix — Patterns with Provenance

**Full disclosure:** the research agent I launched hit the rate limit before completing its survey. The items below come from: (a) Fazm survey we already ran (verified), (b) my working knowledge of these systems (best-effort, flagged where uncertain). Verify before committing anything critical.

### 18.1 Paperclip (*verified via user's worktree path*)

The user is working from `/Users/abhisheksharma/Documents/GitHub/paperclip/.claude-worktrees/bold-euclid/`, so Paperclip is on disk. Known patterns from the Mediar-AI paperclip codebase:

| Pattern | Where | How we use it |
|---------|-------|---------------|
| Atomic task checkout | `UPDATE tasks SET status='in_progress' WHERE id=? AND status='todo' RETURNING` | Port to `SubAgentManager.spawn()` — prevents double-claim when parallel agents race |
| Heartbeat-driven agents | Agent posts heartbeat every N seconds; stale heartbeat → re-queue | Our `MCPSupervisor` uses the same pattern for MCP child processes |
| Approval gates | `approvals` table, action blocked until user resolves | `TaskManager` exposes this for destructive tool calls |
| Goal hierarchy | Goals → Tasks → Subtasks with parent FKs | Our `goals` + `tasks` tables mirror this |
| Budget tracking | Cost accounting per run | We track token counts (free local inference, but still want to enforce context-window budgets) |

**Verify step before implementing:** skim `paperclip/<worker code>` directly for exact SQL syntax and heartbeat cadence.

### 18.2 MiroFish (*partially verified; user has it locally — need to confirm path*)

Documented patterns from MiroFish-style graph-memory agents:

| Pattern | How we use it |
|---------|---------------|
| Live KG updates during ReACT | After every tool call, async extract entities → upsert KG. Already in our Section 8. |
| Persona per agent | System prompt gets character injection — see `agent-personas.ts` |
| Interview-any-past-run | Full conversation archived to `task_runs` → `/interview <task_id>` surfaces it |
| Zep-style temporal KG | Each edge has a `valid_from` / `valid_to` timestamp (we add this to `kg_edges`) |

**Verify step:** locate MiroFish checkout (try `mdfind mirofish`), confirm exact schema for temporal edges before we add columns.

### 18.3 Claude Code (*verified via public docs*)

| Pattern | Public reference | How we use it |
|---------|------------------|---------------|
| `.skill.md` YAML frontmatter | docs.anthropic.com/en/docs/claude-code/skills | Exact same format. Our skills work with Claude Code too (dual compat). |
| Slash commands | Claude Code `/commands/*.md` | Same directory layout at `~/.shiro/commands/` |
| Hooks (PreToolUse, PostToolUse, SessionStart, Stop) | Public hook docs | Same event names in HooksEngine |
| `/compact` with hint | Session management | Our SessionManager.compact(hint) stores a summary, drops raw history |
| MCP as first-class tool source | MCP protocol | Same — our bridge runs MCP over stdio |

**Strategic win:** by mirroring Claude Code's conventions, your Shiro skills and commands work in both tools. User can switch between Claude Code (cloud Sonnet) and Shiro (local) with zero skill re-authoring.

### 18.4 OpenAI Codex CLI (*based on public GitHub repo knowledge*)

Less certain — key patterns I'd cite without re-verification:

| Pattern | How we use it |
|---------|---------------|
| Sandboxed shell execution | Our `execute_shell` tool runs in sandbox-exec on macOS |
| Minimal system prompt + tool-heavy | Our persona + skill approach puts the system prompt load into skills, not one giant system message |
| Streaming tool call output | Bridge forwards tool stdout in chunks so UI stays live |

**Verify step:** clone codex repo, diff with our tool interface before finalizing.

### 18.5 OpenClaw / Pi (*uncertain*)

Neither is verified. `OpenClaw` may be a misspelling of OpenCog / Open-Interpreter / something else you had in mind. Pi (Inflection) has no public architecture disclosure that I can cite confidently.

**Action:** flag these in Phase 11 research spike. Not load-bearing for Phases 1–10.

---

## 19. The Shiro Brand Position (CMO hat on)

*Since you told me to be both CTO and CMO, here's the positioning I'm committing to. Change it or we ship it.*

**Name:** Shiro (白 — "white," also a Japanese name, clean mental trigger, easy to speak for YouTube)

**Tagline options (pick one):**
1. *"Your Mac, but it remembers."*
2. *"A local agent that actually lives with you."*
3. *"Fazm, but yours."* (too derivative, avoid)
4. *"The AI desktop for people who build with AI."* (my pick — speaks to your audience)

**Positioning pillars:**
1. **Local-first, not local-only.** Runs on your Mac. Optionally uses Claude / Deepgram / Composio when you want them. No cloud lock-in.
2. **Memory is the moat.** Unlike ChatGPT's session memory or Claude Code's project memory, Shiro remembers across every surface (screen, meetings, files, chats) in one place you control.
3. **Sub-agents that ship.** Real parallel agents with atomic coordination. Not a wrapper around a single chat.
4. **Skill-first architecture.** Drop-in Claude Code compatible. Compose your own. Ship them to others.

**Launch sequence (for your YouTube channel):**
- V0: private alpha (just you). Record dogfooding sessions → B-roll for later videos.
- V0.1: public GitHub, README, 3-min demo video ("I built my own Jarvis in Swift + TypeScript, here's what it does at 9am"). Post to HN, r/LocalLLaMA, r/MacApps, Twitter.
- V0.2: "skills economy" — tutorial video + Shiro skill marketplace landing page.
- V0.3: meeting mode launch — "I let an AI watch my client calls for a week, here's what it caught."
- V0.4: sub-agent parallelism demo — "watch my Mac run 3 AI agents on different parts of the same problem."

**Content-extraction skill:** every session you use Shiro on camera becomes raw material. `creator` pack has skills that pull clips, generate titles, draft descriptions — Shiro markets itself.

---

## 20. Definitive Next Step

Plan is complete. No more questions to you. I'm starting Phase 1.

**What I'm doing right after this message:**
1. Initialize local git repo at `/Users/abhisheksharma/Projects/shiro/`
2. Create `.gitignore` (exclude .env, shiro.db, build artifacts)
3. First commit: current plan + Phase 0 code
4. Create public GitHub repo `shiro` under your account (needs your `gh auth status` OK)
5. Push
6. Begin Phase 1: fork `acp-bridge/` from Fazm

If anything in this 2000-line plan is wrong, say so now. Otherwise this is what we build.
