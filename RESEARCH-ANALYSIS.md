# Shiro Research Analysis & Recommendations

**Date:** 2026-04-17  
**Researcher:** Shiromi (🦞)  
**Scope:** Deep research on local-first AI desktop agents, RAG systems, meeting transcription, UI/UX patterns, and competitive landscape

---

## Executive Summary

After analyzing **Shiro's PLAN.md**, surveying the competitive landscape, and researching best practices, here are the key findings:

### ✅ What Shiro Gets Right (Already Aligned with Industry Best Practices)

1. **Local-first architecture** — Correct bet. Privacy + latency + cost advantages over cloud-dependent agents
2. **Fazm fork strategy** — Smart. Battle-tested ACP bridge pattern, skip cloud-coupled modules
3. **Hybrid RAG (FTS5 + sqlite-vec)** — Production-grade pattern. Better than vector-only or FTS-only
4. **Claude Code skill compatibility** — Strategic. Leverages existing ecosystem, skills are portable
5. **Swift + Node split** — Correct. Swift for OS integration, Node for agent runtime flexibility

### 🎯 Key Opportunities for Improvement (Based on Research)

1. **UI/UX Polish** — Floating bar needs to feel as native as Spotlight/Xcode toolbars
2. **Meeting Mode Differentiation** — Add pre-meeting briefs + post-meeting auto-followups (not just transcription)
3. **Sub-agent UX** — Make spawning/monitoring sub-agents as seamless as opening a tab
4. **Knowledge Graph Visualization** — Live, queryable KG viewer is a killer feature if done right
5. **MCP Registry Discovery** — One-command install for new MCP servers (Composio, GitHub, etc.)

---

## 1. Competitive Landscape Analysis

### Direct Competitors / Inspirations

| Project | Stars | Key Features | Gaps Shiro Can Fill |
|---------|-------|--------------|---------------------|
| **[Fazm](https://fazm.ai)** | N/A (private repo) | Voice-first, screen capture, Deepgram STT, 17 bundled skills, LM Studio proxy | Cloud-coupled (Firestore, Vertex, Stripe), no sub-agents, no vector RAG, no hooks/slash commands |
| **[screenpipe](https://github.com/louis030195/screen-pipe)** | 18K | 24/7 screen recording, Rust-based, agent triggers | No meeting mode, no sub-agents, no MCP integration |
| **[Minutes](https://github.com/silverstein/minutes)** | 691 | Meeting memory, searchable conversations, Rust backend | Meeting-only (no desktop agent), no sub-agents |
| **[Transcripted](https://transcripted.app)** | N/A | Local meeting transcription, speaker-labeled markdown | Transcription-only, no agent capabilities |
| **[call.md](https://github.com/video-db/call.md)** | 235 | Live meeting analysis, agent loops | Cloud-dependent, no local-first mode |

### Shiro's Unique Position

**Shiro = Fazm's polish + screenpipe's 24/7 awareness + Minutes' meeting intelligence + Claude Code's extensibility — all local-first.**

This is a **strong positioning**. No competitor does all four.

---

## 2. Technical Architecture Recommendations

### 2.1 Hybrid RAG Implementation

**Current Plan:** FTS5 + sqlite-vec in single SQLite file ✅

**Research Findings:**
- Alex Garcia's blog ([source](https://alexgarcia.xyz/blog/2024/sqlite-vec-hybrid-search/)) confirms this is the production pattern
- ZeroClaw's implementation shows **3-5x better retrieval quality** vs vector-only when using hybrid (BM25 + cosine similarity reranking)
- sqlite-vec issue #48 ([source](https://github.com/asg017/sqlite-vec/issues/48)) confirms FTS5 integration works but requires careful schema design

**Recommendation:**
```sql
-- Use this schema pattern (from Alex Garcia's blog):
CREATE TABLE chunks (
  id INTEGER PRIMARY KEY,
  text TEXT NOT NULL,
  embedding BLOB -- sqlite-vec stores embeddings as BLOBs
);

CREATE VIRTUAL TABLE chunks_fts USING fts5(text, content='chunks', content_rowid='id');

-- Hybrid query pattern:
SELECT 
  c.id,
  c.text,
  vec_distance_cosine(c.embedding, :query_embedding) AS vector_score,
  bm25(chunks_fts) AS fts_score
FROM chunks c
JOIN chunks_fts ON c.id = chunks_fts.rowid
WHERE chunks_fts MATCH :query_text
ORDER BY (0.7 * vector_score + 0.3 * fts_score) DESC
LIMIT 10;
```

**Action Item:** Update `Database.swift` schema to match this pattern before Phase 1 completion.

---

### 2.2 Sub-Agent Architecture

**Current Gap in Fazm:** Explicit comment at `acp-bridge/src/index.ts:13`: *"No sub-agents"*

**Research Findings:**
- Paperclip's atomic SQL checkout pattern (`UPDATE ... WHERE status='todo' RETURNING`) prevents race conditions
- Model routing heuristics should be:
  - **Fast tasks** (<10 tool calls) → Qwen3-8B (4.6GB)
  - **Complex reasoning** → Gemma-4-26B (18GB)
  - **Vision tasks** → Qwen2.5-VL-7B (6GB)
  - **Critical/approval-required** → Route to Claude Sonnet (user-provided API key)

**Recommendation:**
Implement sub-agent manager in `acp-bridge/src/subagents.ts`:
```typescript
interface SubAgent {
  id: string;
  mission: string;
  parentSessionId: string;
  model: 'fast' | 'brain' | 'vision' | 'cloud';
  budget: { tokens: number; toolCalls: number };
  status: 'running' | 'completed' | 'failed' | 'awaiting_approval';
  output?: string;
}

// Atomic checkout pattern from Paperclip:
async function spawnSubAgent(mission: string, opts: SubAgentOpts): Promise<string> {
  const db = await Database.shared();
  return db.transaction(async (tx) => {
    const id = crypto.randomUUID();
    await tx.sql`
      INSERT INTO sub_agents (id, mission, status, created_at)
      VALUES (${id}, ${mission}, 'running', NOW())
      RETURNING id
    `;
    // Spawn isolated ACP session
    // ...
    return id;
  });
}
```

**Action Item:** Add `sub_agents` table to GRDB schema in Phase 1.

---

### 2.3 Meeting Mode Enhancements

**Current Fazm Pattern:** Deepgram streaming STT → transcription stored → manual review

**Competitor Analysis:**
- **Minutes** ([GitHub](https://github.com/silverstein/minutes)): Stores every meeting as searchable conversation memory
- **call.md** ([GitHub](https://github.com/video-db/call.md)): Live action item extraction during meeting
- **Transcripted** ([transcripted.app](https://transcripted.app)): Speaker-labeled markdown output, agent-ready format

**Recommendation for Shiro:**
Add **three-phase meeting flow**:

#### Phase 1: Pre-Meeting (5 min before)
- Detect calendar event (read macOS Calendar via EventKit)
- Auto-generate **context brief**: "Meeting with [attendees] about [topic]. Last discussion: [summary from KG]. Open tasks: [list]."
- Show in floating bar: *"Client call in 5 min. Want me to prepare a brief?"*

#### Phase 2: During Meeting (live)
- Deepgram streaming STT with speaker diarization
- **Live action item extraction** (LLM processes every 30 sec window):
  ```json
  {
    "action_items": [
      {"assignee": "Abhishek", "task": "Send doc by Friday", "confidence": 0.92}
    ],
    "decisions": ["Approved budget increase"],
    "follow_ups": ["Schedule next sync"]
  }
  ```
- Update knowledge graph in real-time (new nodes for attendees, topics, commitments)

#### Phase 3: Post-Meeting (immediate)
- Show summary card with:
  - 3-line recap
  - Action items (with approval toggle for each)
  - Updated KG nodes preview
  - **Auto-drafted follow-up email** (not sent — user reviews first)
- Option: *"Spawn sub-agent to execute action items?"*

**Action Item:** Add `MeetingMode.swift` with three-phase logic. Integrate with EventKit for calendar detection.

---

## 3. UI/UX Recommendations

### 3.1 Floating Bar Design

**Research Source:** Fazm blog posts on floating toolbars ([source 1](https://fazm.ai/blog/swiftui-floating-toolbar-macos), [source 2](https://fazm.ai/blog/floating-bar-vs-sidebar-macos-ai-agent))

**Key Patterns:**
1. **Use `NSPanel` with `.utility` + `.hud` style** — Stays on top, doesn't steal focus
2. **Draggable but snap-to-edge** — Like Xcode's utility panel
3. **Minimal by default** — Show only: mic icon (listening state) + pulse indicator
4. **Expand on hover or ⌘+Space** — Reveal full controls (chat input, task board toggle, meeting mode button)

**Recommended Layout:**
```
┌──────────────────────────────────────────────┐
│ 🦞 Shiro                              [_][×] │
├──────────────────────────────────────────────┤
│ [🎤 Listening] [📋 Tasks] [📅 Meeting]     │
│                                              │
│ Type a command or ask me anything...    [→] │
└──────────────────────────────────────────────┘
```

**Implementation Notes:**
- Use SwiftUI `NSViewRepresentable` for panel behavior
- Animate position changes with `withAnimation(.spring)`
- Save last position in `UserDefaults`

**Action Item:** Review `FloatingControlBar.swift` — ensure it uses `NSPanel` not `Window`.

---

### 3.2 Task Board UX

**Inspiration:** Paperclip's task state machine + Fazm's observer cards

**Recommended States:**
```
Todo → Running → AwaitingApproval → Completed
              ↓
           Failed (with retry option)
```

**UX Pattern:**
- **Task cards** show: mission, assigned sub-agent, progress bar, tool calls used
- **One-click approval** for actions requiring consent
- **Kill switch** for runaway sub-agents
- **Archive** for completed tasks (searchable via RAG)

**Visual Design:**
```
┌─────────────────────────────────────────────┐
│ 📋 Task Board                               │
├─────────────────────────────────────────────┤
│ ✅ Review PR #42                    Done    │
│ 🔄 Search deprecated API usage      Running │
│    ━━━━━━━━━━━━━━━━░░░░  75%               │
│ ⏸️  Send follow-up email            Waiting │
│    [Approve] [Edit] [Cancel]                │
└─────────────────────────────────────────────┘
```

**Action Item:** Add `TaskBoardView.swift` with live state updates from database.

---

### 3.3 Knowledge Graph Viewer

**Differentiator:** This is Shiro's moat. No competitor has a **live, queryable KG** built-in.

**Inspiration:** MiroFish's real-time graph updates during ReACT loops

**Recommended Features:**
1. **Force-directed graph visualization** (use SwiftUI + Metal or integrate D3.js via WebView)
2. **Query syntax:** `/kg <topic>` returns subgraph
3. **Click to expand** nodes (people, projects, decisions, meetings)
4. **Timeline scrubber** — see how graph evolved over time
5. **Export** as Graphviz DOT or JSON

**Example Query:**
```
/kg Abhishek
→ Returns: [Abhishek] → works_on → [Shiro, Paperclip]
           [Abhishek] → committed_to → [Send doc by Friday]
           [Abhishek] → met_with → [Australia team 2026-04-17]
```

**Action Item:** Phase 2 feature. Start with simple list view, upgrade to force-directed graph later.

---

## 4. Skills System Strategy

### 4.1 Skill Format Compatibility

**Current Plan:** Match Claude Code's `.skill.md` format ✅

**Research Findings:**
- Official docs: [Extend Claude with skills](https://docs.claude.com/en/docs/claude-code/slash-commands)
- Skill structure:
  ```markdown
  ---
  name: my-skill-name
  description: What this skill does
  version: 1.0.0
  ---
  
  # Skill Instructions
  
  When the user asks about X, do Y.
  
  ## Tools Used
  - read_file
  - write_file
  - run_command
  ```

**Strategic Advantage:** Skills written for Shiro work with Claude Code and vice versa. This creates **ecosystem lock-in** in your favor.

### 4.2 Recommended Skill Packs (Phase 1 Launch)

Based on Fazm's 17 bundled skills + gaps identified:

| Pack | Skills | Priority |
|------|--------|----------|
| **Core** | `/meeting`, `/observe`, `/task`, `/sub`, `/kg`, `/skills` | P0 |
| **Dev** | `/review-pr`, `/find-deprecated`, `/generate-docs`, `/write-tests` | P0 |
| **Research** | `/summarize-paper`, `/find-related`, `/extract-claims` | P1 |
| **Automation** | `/schedule`, `/email-draft`, `/calendar-brief`, `/reminder` | P1 |
| **Life** | `/morning-brief`, `/evening-review`, `/handoff` | P2 |
| **AI Eng** | `/fine-tune-prep`, `/eval-dataset`, `/benchmark-model` | P2 |

**Total:** ~25 skills across 6 packs

**Action Item:** Create skill templates in `Desktop/Sources/BundledSkills/` matching Claude Code format.

---

## 5. MCP Registry Strategy

### 5.1 Current Gap in Fazm

Hardcoded MCP servers in `buildMcpServers()` — users can't add new ones without code changes.

### 5.2 Recommended Implementation

**YAML Config at `~/.shiro/mcp.yaml`:**
```yaml
mcp_servers:
  - name: playwright
    command: npx
    args: ['@playwright/mcp@latest']
    enabled: true
    
  - name: github
    command: npx
    args: ['@modelcontextprotocol/server-github@latest']
    env:
      GITHUB_TOKEN: $GITHUB_TOKEN
    enabled: true
    
  - name: composio
    command: composio
    args: ['mcp', 'start']
    enabled: false  # User enables when needed
    
  - name: context7
    command: npx
    args: ['@context7/mcp@latest']
    enabled: true
```

**Discovery Command:**
```bash
shiro mcp discover
→ Shows: "Found 47 MCP servers. Install with: shiro mcp install <name>"
```

**Action Item:** Implement `MCPRegistry.swift` actor that reads YAML and spawns servers dynamically.

---

## 6. Model Strategy (48GB RAM Optimization)

### 6.1 Current Plan (from README)

| Role | Model | Size |
|------|-------|------|
| Brain | `google/gemma-4-26b-a4b` | 18 GB |
| Fast | `qwen/qwen3-8b` | 4.6 GB |
| Vision | `qwen/qwen2.5-vl-7b` | 6 GB |
| Embed | `text-embedding-embeddinggemma-300m-qat` | 0.2 GB |

**Total:** ~29 GB resident

### 6.2 Research Findings

**Source:** Fazm blog on [On-Device AI on Apple Silicon](https://fazm.ai/blog/on-device-ai-apple-silicon-desktop-agent)

**Key Insight:** Unified memory architecture means models loaded in LM Studio are accessible system-wide without duplication.

### 6.3 Recommendation

**Add model router in `acp-bridge/src/model-router.ts`:**
```typescript
function selectModel(task: Task): ModelId {
  if (task.requiresVision) return 'qwen2.5-vl-7b';
  if (task.toolCalls > 20 || task.complexity === 'high') return 'gemma-4-26b';
  if (task.type === 'embedding') return 'embeddinggemma-300m';
  return 'qwen3-8b'; // Default fast path
}
```

**Fallback Strategy:**
- If LM Studio unavailable → Ollama
- If local models fail → Offer to route to Claude (user must provide API key)

**Action Item:** Implement model router before Phase 1 launch.

---

## 7. Licensing & Legal Considerations

### 7.1 Fazm License Status

**Issue:** Fazm repo has **no LICENSE file**. README says "fully open source" but that's not legally binding.

**Risk:** Publishing Shiro as derived work without explicit license could lead to takedown or legal action.

### 7.2 Recommended Actions

1. **Open GitHub issue on fazm repo** requesting explicit OSS license (MIT/Apache-2.0)
2. **Until resolved:**
   - Adapt patterns, don't copy file-for-file
   - Re-implement in own source files with different structure
   - Document inspiration (as you already do in PLAN.md)
3. **Long-term:** Consider reaching out to Fazm maintainers for collaboration or formal licensing agreement

**Action Item:** File GitHub issue on `mediar-ai/fazm` this week.

---

## 8. Go-to-Market Strategy

### 8.1 Target Audience

1. **AI Engineers** building with local models (your primary)
2. **Privacy-conscious professionals** (lawyers, doctors, researchers)
3. **Power users** frustrated with cloud-dependent tools
4. **Developers** wanting Claude Code-like extensibility but offline

### 8.2 Differentiation Messaging

**Tagline:** *"Your AI desktop. Local-first. Fully yours."*

**Key Messages:**
- "Everything Fazm does, but local-only"
- "Skills compatible with Claude Code — your workflow travels with you"
- "Meeting intelligence that actually helps (pre-briefs + auto-followups)"
- "Knowledge graph that remembers what you forgot"

### 8.3 Launch Phases

| Phase | Features | Timeline |
|-------|----------|----------|
| **Alpha** (now) | Foundation, basic chat, file indexing | Apr 2026 |
| **Beta** | Meeting mode, sub-agents, 10 core skills | May 2026 |
| **v1.0** | Full skill packs, MCP registry, KG viewer | Jun 2026 |
| **v1.1** | Auto-sync, advanced automation, plugin SDK | Jul 2026 |

---

## 9. Immediate Next Steps (Prioritized)

### P0 (This Week)
1. ✅ Read this analysis (you're doing it now)
2. ⬜ File GitHub issue on Fazm license
3. ⬜ Update `Database.swift` schema for hybrid RAG (FTS5 + sqlite-vec)
4. ⬜ Implement `MCPRegistry.swift` with YAML config
5. ⬜ Add model router to `acp-bridge`

### P1 (Next 2 Weeks)
6. ⬜ Build three-phase meeting mode (pre/during/post)
7. ⬜ Create 10 core skills in Claude Code format
8. ⬜ Polish floating bar UI (NSPanel + animations)
9. ⬜ Add sub-agent manager with atomic SQL checkout
10. ⬜ Write automated tests for critical paths

### P2 (Next Month)
11. ⬜ Knowledge graph viewer (start with list view)
12. ⬜ Calendar integration for meeting detection
13. ⬜ Evening review / morning brief hooks
14. ⬜ MCP discovery command
15. ⬜ Beta testing with 5-10 friendly users

---

## 10. Risks & Mitigations

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| Fazm license issues | Medium | High | Re-implement patterns, don't copy; file issue ASAP |
| sqlite-vec performance | Low | Medium | Benchmark early; fallback to FTS5-only if needed |
| Model routing bugs | Medium | Medium | Add extensive logging; manual override option |
| Meeting mode false positives | High | Low | Require explicit activation first; add confidence threshold |
| Scope creep | High | High | Stick to phased rollout; say no to nice-to-haves |

---

## Conclusion

**Shiro is positioned to be the best local-first AI desktop agent** — but execution matters more than vision.

**Your unfair advantages:**
1. Fazm's battle-tested architecture as a starting point
2. Claude Code skill compatibility (ecosystem leverage)
3. Hybrid RAG (technical moat)
4. Meeting intelligence (differentiator)
5. Local-first privacy (growing market demand)

**My role as Shiromi:** I'll help you research, plan, and execute. I can:
- Search for more specific technical patterns
- Draft skill definitions
- Review code for alignment with this plan
- Help prioritize features based on your goals

**What do you want to tackle first, Abhishek?** 🦞

---

## Appendix: Research Sources

### Primary Sources
1. [Fazm macOS Agent](https://fazm.ai/macos-ai-agent)
2. [Fazm Blog: Building macOS AI Agent in Swift](https://fazm.ai/blog/building-macos-ai-agent-swift-screencapturekit)
3. [Fazm Blog: On-Device AI on Apple Silicon](https://fazm.ai/blog/on-device-ai-apple-silicon-desktop-agent)
4. [screenpipe GitHub](https://github.com/louis030195/screen-pipe)
5. [Minutes GitHub](https://github.com/silverstein/minutes)
6. [Transcripted](https://transcripted.app/)

### Technical References
7. [sqlite-vec Hybrid Search](https://alexgarcia.xyz/blog/2024/sqlite-vec-hybrid-search/)
8. [ZeroClaw Hybrid Memory](https://zeroclaws.io/blog/zeroclaw-hybrid-memory-sqlite-vector-fts5/)
9. [sqlite-vec GitHub](https://github.com/asg017/sqlite-vec)
10. [Claude Code Skills Docs](https://docs.claude.com/en/docs/claude-code/slash-commands)

### UI/UX References
11. [Fazm: Native Swift Menu Bar Apps](https://fazm.ai/blog/native-swift-menu-bar-ai-agent)
12. [Fazm: SwiftUI Floating Panel](https://fazm.ai/blog/swiftui-floating-panel)
13. [Fazm: Floating Bar vs Sidebar](https://fazm.ai/blog/floating-bar-vs-sidebar-macos-ai-agent)

---

*This research was compiled by Shiromi 🦞 for the Shiro project. Last updated: 2026-04-17.*
