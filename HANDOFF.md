## Session: 2026-04-18

## What Was Done
All 7 planned phases built and compiling clean (Swift + TypeScript).

- **Phase 3 — Vector RAG**: `EmbeddingService.swift` (LRU-cached batch embed), `MemoryStore.swift` (vDSP cosine + FTS5 RRF fusion), `Ingestor.swift` (code/markdown/text chunking, mtime-gated). DB v3 migration adds `memory_chunks` + `ingest_jobs` + FTS5 virtual table. `search_memory` tool in ACPBridge wired to real results. Auto-ingest `~/Projects` on launch.
- **Phase 2.5 — Telegram relay**: `TelegramRelay.swift` — long-poll bot, sends approval cards with inline keyboard (✅/❌/🚫), edits message after decision. `ConsentGate` fires relay in parallel on high-risk suspensions. Audit log records `"telegram"` vs `"ui"` channel. Enabled via `TELEGRAM_BOT_TOKEN` + `TELEGRAM_CHAT_ID` env vars.
- **Phase 4 — MCP registry**: `~/.shiro/mcp.json` auto-created with GitHub/Context7/Filesystem/Composio/HuggingFace. `mcp-registry.ts` (Node) expands `${VAR}` and merges external servers into every `query()` call alongside built-in shiro server. `MCPRegistry.swift` surfaces list in SettingsView with live enable/disable toggles.
- **Phase 5 — Skills system**: `SkillsRegistry.swift` + `~/.shiro/skills/*.json`. 6 built-in skills: `research`, `summarise-meeting`, `code-review` (`/review`), `draft-email` (`/email`), `daily-brief` (`/brief`), `ingest`. Slash command routing in FloatingBarView (user types `/research topic` → skill's system prompt + filled template sent). `invoke_skill` tool lets agent call skills. Badge shown on user bubble.
- **Phase 6 — Hooks engine**: `HooksEngine.swift` — `app_launch`, `file_watch` (DispatchSource), `schedule` (daily HH:MM or every:N minutes). Default hooks: watch `COLLABORATION.md`, daily-brief at 09:00 (disabled), ingest-on-launch (disabled). Config: `~/.shiro/hooks.json`.
- **Phase 7 — Meeting mode UI**: `MeetingModeView.swift` — pulsing amber REC dot, live transcript with HH:MM:SS timestamps, per-segment green flash, auto-summary card (calls `summarise-meeting` skill on STT flush), mute toggle, End Meeting → saves `MeetingSession` to DB + triggers full summarise. Waveform button in main bar toggles mode.

## What Works
- `swift build` → Build complete (verified 2026-04-18)
- `cd acp-bridge && npm run build` → clean tsc compile (verified 2026-04-18)
- Full init chain in `AppState.initialize()`: DB → LMStudio → KG → STT → Screen → Coordinator → ConsentGate → SubAgentManager → TelegramRelay → ACP Bridge → MCPRegistry → SkillsRegistry → HooksEngine → EmbeddingService → MemoryStore → Ingestor

## What's Broken / Blockers
- **Not runtime-tested** — no LM Studio running in CI. All builds are compile-only verified.
- `acp-bridge/dist/` must exist before Swift launches the bridge: run `cd acp-bridge && npm run build` first.
- Telegram long-poll uses `URLSession.shared` — works but not cancellable mid-request on app quit. Low priority.
- `Ingestor.swift:96` has a Swift 6 warning (`makeIterator` async context) — not an error, safe to ignore for now.

## Next Steps (Priority Order)
1. **Run end-to-end**: Launch LM Studio with all 4 models → `npm run build` in acp-bridge → `swift run` → type a message → confirm streaming works
2. **Set env vars for Telegram**: `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID` in Xcode scheme → test approval card flow with a `shell_exec` command
3. **Enable GitHub MCP**: Set `GITHUB_PERSONAL_ACCESS_TOKEN` env var → toggle `github` server on in Settings → restart
4. **Test `/research` skill**: Type `/research Swift concurrency` in the bar → confirm skill badge appears + correct system prompt used
5. **Test meeting mode**: Click waveform button → speak → confirm transcript lines appear → click "Summarise" → confirm skill fires
6. **COLLABORATION.md hook**: Shiromi writes to `~/Projects/shiro/COLLABORATION.md` → confirm hook fires and agent receives the query

## Files Modified (this session)
- `Sources/Memory/Database.swift` — v3 migration, `MemoryChunk` + `IngestJob` records
- `Sources/Memory/EmbeddingService.swift` — NEW
- `Sources/Memory/MemoryStore.swift` — NEW (vDSP cosine + FTS5 RRF)
- `Sources/Memory/Ingestor.swift` — NEW
- `Sources/Memory/MCPRegistry.swift` — NEW
- `Sources/Bridge/TelegramRelay.swift` — NEW
- `Sources/Bridge/ACPBridge.swift` — added `memoryStore`, `skillsRegistry`, `search_memory` + `invoke_skill` tools, `searchMemoryTool()`
- `Sources/Agent/ConsentGate.swift` — `telegramRelay` ref, parallel Telegram notify, channel audit, `resolve()` channel param
- `Sources/Agent/SkillsRegistry.swift` — NEW
- `Sources/Agent/HooksEngine.swift` — NEW
- `Sources/App/AppState.swift` — all new services wired
- `Sources/App/Config.swift` — Telegram + MCP config keys
- `Sources/UI/FloatingBar/FloatingBarView.swift` — slash routing, meeting button, badge, MCP settings section
- `Sources/UI/FloatingBar/MeetingModeView.swift` — NEW
- `acp-bridge/src/mcp-registry.ts` — NEW
- `acp-bridge/src/index.ts` — external MCP servers merged into runQuery()

## Must-Know Context
- Node bridge path is hardcoded to `/Users/abhisheksharma/Projects/shiro/acp-bridge/dist/index.js` — override with `SHIRO_BRIDGE_PATH` env var
- Node binary hardcoded to `/Users/abhisheksharma/node-v20.12.2-darwin-arm64/bin/node` — override with `SHIRO_NODE_PATH`
- Embedding model: `text-embedding-embeddinggemma-300m-qat` (768-dim) — must be loaded in LM Studio
- DB file: `~/Library/Application Support/Shiro/shiro.db` — delete to reset all state
- Config files live in `~/.shiro/`: `mcp.json`, `hooks.json`, `skills/*.json` — all auto-created on first run
- `COLLABORATION.md` at `~/Projects/shiro/COLLABORATION.md` — Shiromi writes here, HooksEngine watches it
