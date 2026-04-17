# Shiro

**The AI desktop for people who build with AI.**

A local-first autonomous agent for macOS. Watches your screen, listens to your meetings, remembers your work, spawns parallel sub-agents, and plugs into the MCP ecosystem (GitHub, Composio, Context7, HuggingFace).

Think of it as [Fazm](https://github.com/mediar-ai/fazm), rebuilt local-only, with real sub-agents and production-grade RAG on top.

---

## Status

**Alpha / heavy WIP.** Phase 0 (foundation) is in. Phase 1 (Node bridge fork) starts now. See [`PLAN.md`](./PLAN.md) for the full 2000-line master plan — every module spec'd before a line is written.

---

## What's in the box (when complete)

- **Swift/SwiftUI macOS app** — floating bar, task board, meeting overlay, KG viewer.
- **Node/TypeScript agent bridge** — forked from Fazm, speaks [ACP](https://github.com/zed-industries/agent-client-protocol). Hot-swap between LM Studio, Ollama, and Claude.
- **Parallel sub-agents** — atomic SQL checkout, persona injection, depth/budget guards.
- **Hybrid RAG** — sqlite-vec + FTS5 in a single SQLite file. Auto-ingests your code, papers, meetings, screen history.
- **Knowledge graph** — live-updating during every tool call. Query with `/kg <topic>`.
- **MCP registry** — declarative `~/.shiro/mcp.yaml`. Bundled: Playwright, GitHub, Composio, Context7, HuggingFace, filesystem, macos-use.
- **Meeting mode** — ScreenCaptureKit mixed audio + Deepgram streaming. Action items extracted live. Approval-gated follow-up.
- **Skills system** — Claude Code compatible `.skill.md` format. 60+ skills planned across 6 packs (learn / creator / automation / ai-eng / work / life).
- **Slash commands + hooks** — scriptable like Claude Code.

---

## Stack

- macOS 14+ (Apple Silicon)
- Swift + SwiftUI + GRDB + sqlite-vec
- Node 20 (bundled) + TypeScript + `@agentclientprotocol/claude-agent-acp` SDK
- LM Studio (primary) / Ollama (fallback) for local inference
- Deepgram Nova-3 for streaming STT
- MCP servers for external tools

---

## Running models (in 48GB RAM)

| Role | Model | Size |
|------|-------|------|
| Brain | `google/gemma-4-26b-a4b` | 18 GB |
| Fast | `qwen/qwen3-8b` | 4.6 GB |
| Vision | `qwen/qwen2.5-vl-7b` | 6 GB |
| Embed | `text-embedding-embeddinggemma-300m-qat` | 0.2 GB |

All loaded in LM Studio simultaneously. ~29 GB resident.

---

## Credits

- **[Fazm](https://github.com/mediar-ai/fazm)** — primary architectural inspiration. We fork the Swift↔Node ACP bridge pattern, LM Studio proxy, and SkillInstaller. Rewritten-from-scratch-not-copied where license is ambiguous.
- **Paperclip** (Mediar-AI) — task state machine + atomic checkout pattern.
- **MiroFish** — knowledge graph live-update pattern.
- **[Claude Code](https://docs.anthropic.com/en/docs/claude-code)** — skill format, slash commands, hooks engine.

---

## License

MIT. See [`LICENSE`](./LICENSE).

---

*Built in the open by [@abhisheksharma001](https://github.com/abhisheksharma001). Follow along on YouTube for build logs.*
