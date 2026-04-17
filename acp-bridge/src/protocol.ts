/**
 * Shiro ↔ Bridge JSON-lines protocol.
 *
 * Swift app spawns the bridge as a child process. They exchange one JSON
 * object per line over stdin/stdout. Sub-agent / observer tool callbacks
 * go through a separate Unix domain socket (see BridgeSocketServer.swift
 * and shiro-tools-stdio.ts).
 *
 * Design notes:
 * - Everything is line-delimited JSON. No framing headers, no length
 *   prefixes. Keeps Swift side trivially parseable.
 * - Every outbound message carries `sessionId` so Swift can demux
 *   concurrent sub-agents into their own UI lanes.
 * - Inbound `sessionKey` is Swift's stable handle for a logical session
 *   (e.g. "main", "agent:123"). The bridge maps it to an ACP sessionId.
 */

// ============================================================================
// Swift → Bridge  (stdin, one JSON object per line)
// ============================================================================

export interface QueryAttachment {
  path: string;
  name: string;
  mimeType: string;
}

/** Primary user message — "send this prompt to the agent". */
export interface QueryMessage {
  type: "query";
  id: string;                       // client-side correlation id
  prompt: string;
  systemPrompt?: string;
  sessionKey?: string;              // default: "main"
  cwd?: string;
  mode?: "ask" | "act";             // ask = read-only, act = can mutate
  model?: string;                   // "claude-sonnet-4-6" | "qwen/qwen3-8b" | ...
  resume?: string;                  // ACP sessionId to resume
  attachments?: QueryAttachment[];
}

/** Response to a tool_use forwarded earlier from the bridge. */
export interface ToolResultMessage {
  type: "tool_result";
  callId: string;
  result: string;                   // stringified; bridge does not parse
  isError?: boolean;
  denied?: boolean;                 // true if user rejected via Consent Gate
  denialReason?: string;
}

/** Swift reports an approval decision out-of-band (e.g. Telegram callback
 *  arrived after a tool_result was already resolved as denied — logged for
 *  audit only). Bridge just echoes to stdout log. */
export interface ApprovalAuditMessage {
  type: "approval_audit";
  callId: string;
  decision: "approve" | "deny" | "remember_deny";
  channel: "ui" | "telegram" | "auto";
  approverId?: string;              // phone handle / user id
  timestamp: number;                // unix ms
}

/** Gracefully shut the bridge down. */
export interface StopMessage {
  type: "stop";
}

/** Interrupt the current in-flight prompt for a session. */
export interface InterruptMessage {
  type: "interrupt";
  sessionKey?: string;              // omit to interrupt all
}

/** Pre-create sessions (system prompts applied once on session/new). */
export interface WarmupSessionConfig {
  key: string;
  model: string;
  systemPrompt?: string;
  resume?: string;
}

export interface WarmupMessage {
  type: "warmup";
  cwd?: string;
  sessions?: WarmupSessionConfig[];
}

/** Force session drop — next query on this key opens a fresh ACP session. */
export interface ResetSessionMessage {
  type: "resetSession";
  sessionKey?: string;
}

/** Spawn a sub-agent. The bridge creates a new ACP session keyed by
 *  `sessionKey` with its own system prompt, independent of "main". */
export interface SpawnAgentMessage {
  type: "spawn_agent";
  sessionKey: string;               // e.g. "agent:task-42"
  parentSessionKey?: string;        // "main" — for context/routing
  taskId: string;
  persona: string;                  // system prompt snippet
  prompt: string;                   // initial task
  model?: string;
  depthBudget?: number;             // max nested sub-agent depth
  costBudgetUsd?: number;           // hard cap; bridge interrupts on breach
  cwd?: string;
}

export type InboundMessage =
  | QueryMessage
  | ToolResultMessage
  | ApprovalAuditMessage
  | StopMessage
  | InterruptMessage
  | WarmupMessage
  | ResetSessionMessage
  | SpawnAgentMessage;

// ============================================================================
// Bridge → Swift  (stdout, one JSON object per line)
// ============================================================================

/** Session was created/resumed. */
export interface InitMessage {
  type: "init";
  sessionId: string;
  sessionKey: string;
}

/** Streaming text token. */
export interface TextDeltaMessage {
  type: "text_delta";
  sessionId: string;
  sessionKey: string;
  text: string;
}

/** Extended thinking token (for models that emit separate reasoning). */
export interface ThinkingDeltaMessage {
  type: "thinking_delta";
  sessionId: string;
  sessionKey: string;
  text: string;
}

/** Paragraph/block boundary between text chunks. */
export interface TextBlockBoundaryMessage {
  type: "text_block_boundary";
  sessionId: string;
  sessionKey: string;
}

/** Risk classification for the Consent Gate.
 *  - low:  read-only, idempotent, local (read_file, sql_read, get_weather)
 *  - med:  external I/O but reversible (web_fetch, git_status, screenshot)
 *  - high: mutates user state, sends, spends, clicks, or writes anywhere
 *          outside Shiro's own DB (shell_exec, file_write, send_email,
 *          macos_click, git_push, stripe_charge)
 *  Default when not specified: "high". */
export type ToolRiskLevel = "low" | "med" | "high";

/** The model wants to call a tool. Swift should answer with ToolResultMessage
 *  referencing the same callId — unless this is an MCP tool, in which case
 *  the bridge handles it internally.
 *
 *  Consent Gate: Swift inspects `riskLevel` and its per-tool policy. If the
 *  policy requires approval, Swift shows an approval card (floating bar +
 *  Telegram echo) before executing, and only then emits `tool_result`. For
 *  `low`, Swift may auto-approve. For `med`, Swift may show a toast with a
 *  brief veto window. `high` is always blocking.
 *
 *  `justification` is the model's own explanation (extracted from the
 *  preceding assistant text block or the tool schema's `x-justification`
 *  field) — surfaced verbatim on the approval card so the user sees WHY
 *  the tool was invoked, not just the raw args. */
export interface ToolUseMessage {
  type: "tool_use";
  sessionId: string;
  sessionKey: string;
  callId: string;
  name: string;
  input: Record<string, unknown>;
  riskLevel: ToolRiskLevel;
  justification?: string;
}

/** UI affordance: tool spinner start/stop. */
export interface ToolActivityMessage {
  type: "tool_activity";
  sessionId: string;
  sessionKey: string;
  name: string;
  status: "started" | "completed";
  toolUseId?: string;
  input?: Record<string, unknown>;
}

/** Rendered tool output for the chat transcript. */
export interface ToolResultDisplayMessage {
  type: "tool_result_display";
  sessionId: string;
  sessionKey: string;
  toolUseId: string;
  name: string;
  output: string;
  isError?: boolean;
}

/** Terminal message of one assistant turn. */
export interface ResultMessage {
  type: "result";
  sessionId: string;
  sessionKey: string;
  text: string;
  inputTokens?: number;
  outputTokens?: number;
  costUsd?: number;
}

export interface ErrorMessage {
  type: "error";
  sessionId?: string;
  sessionKey?: string;
  message: string;
}

/** Sub-agent lifecycle (sent for every `spawn_agent` the parent requests). */
export interface AgentStartedMessage {
  type: "agent_started";
  sessionId: string;
  sessionKey: string;
  taskId: string;
  persona: string;
}

export interface AgentFinishedMessage {
  type: "agent_finished";
  sessionId: string;
  sessionKey: string;
  taskId: string;
  status: "completed" | "failed" | "stopped";
  summary: string;
  totalCostUsd?: number;
}

/** Generic log line from the bridge — surfaced in debug console. */
export interface LogMessage {
  type: "log";
  level: "info" | "warn" | "error";
  message: string;
}

export type OutboundMessage =
  | InitMessage
  | TextDeltaMessage
  | ThinkingDeltaMessage
  | TextBlockBoundaryMessage
  | ToolUseMessage
  | ToolActivityMessage
  | ToolResultDisplayMessage
  | ResultMessage
  | ErrorMessage
  | AgentStartedMessage
  | AgentFinishedMessage
  | LogMessage;

// ============================================================================
// Tools-stdio  ↔  Parent bridge  (Unix domain socket, line-delimited JSON)
// ============================================================================
// These messages flow between the MCP subprocess (shiro-tools-stdio.ts) and
// the parent acp-bridge process over a Unix socket whose path is passed in
// the SHIRO_BRIDGE_SOCKET env var.

export interface PipeToolUseMessage {
  type: "tool_use";
  callId: string;
  name: string;
  input: Record<string, unknown>;
  sessionKey?: string;
  riskLevel?: ToolRiskLevel;
  justification?: string;
}

export interface PipeToolResultMessage {
  type: "tool_result";
  callId: string;
  result: string;
  isError?: boolean;
}

export interface PipeLogMessage {
  type: "log";
  level: "info" | "warn" | "error";
  message: string;
}

export type PipeMessage =
  | PipeToolUseMessage
  | PipeToolResultMessage
  | PipeLogMessage;
