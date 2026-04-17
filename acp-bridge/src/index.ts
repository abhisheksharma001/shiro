/**
 * Shiro ACP Bridge — entry point.
 *
 * Spawned by the Swift app. Reads `InboundMessage`s from stdin, writes
 * `OutboundMessage`s to stdout. Uses the Claude Agent SDK (`query`)
 * in-process to drive the LLM, points it at the local LM Studio proxy
 * we boot alongside, and exposes our MCP tool server
 * (`shiro-tools-stdio.js`) so the model can reach Swift.
 *
 * Tool-call routing:
 *
 *   Swift ──stdin──> bridge ──SDK──> query()
 *                                       │
 *                                       ├─ MCP subprocess (shiro-tools-stdio.js)
 *                                       │     │
 *                                       │     └─ Unix socket ──> bridge
 *                                       │                         │
 *                                       │    ┌────────────────────┤  forwards tool_use
 *                                       │    ▼                    │
 *                                       │  Swift ─── stdout ──────┘
 *                                       │    │
 *                                       │    └── tool_result ──stdin──> bridge
 *                                       │                                    │
 *                                       │            socket.write ───────────┘
 *                                       ▼
 *                                 SDKMessage stream → OutboundMessage → stdout → Swift
 */

import { spawn, type ChildProcess } from "child_process";
import { createInterface } from "readline";
import { createServer as createNetServer, type Server as NetServer, type Socket } from "net";
import { dirname, join } from "path";
import { fileURLToPath } from "url";
import { tmpdir } from "os";
import { unlinkSync, existsSync } from "fs";
import { randomUUID } from "crypto";

import type {
  InboundMessage,
  OutboundMessage,
  QueryMessage,
  SpawnAgentMessage,
  ToolResultMessage,
  PipeMessage,
  PipeToolUseMessage,
  ToolRiskLevel,
} from "./protocol.js";
import { startLMStudioProxy } from "./lm-studio-proxy.js";

const __dirname = dirname(fileURLToPath(import.meta.url));
const toolsStdioPath = join(__dirname, "shiro-tools-stdio.js");

// ---------------------------------------------------------------------------
// stdout / stderr plumbing
// ---------------------------------------------------------------------------

function send(msg: OutboundMessage): void {
  try {
    process.stdout.write(JSON.stringify(msg) + "\n");
  } catch (err) {
    process.stderr.write(`[bridge] stdout write failed: ${err}\n`);
  }
}

function log(level: "info" | "warn" | "error", message: string): void {
  process.stderr.write(`[bridge ${level}] ${message}\n`);
  send({ type: "log", level, message });
}

// ---------------------------------------------------------------------------
// Unix socket server — receives PipeMessage from MCP subprocesses
// ---------------------------------------------------------------------------

interface PendingToolCall {
  /** The MCP-subprocess socket connection that should receive the result. */
  socket: Socket;
  /** The sessionKey the tool call originated from (for UI demux). */
  sessionKey: string;
  /** When the call was issued (for logging). */
  startedAt: number;
}

const pendingToolCalls = new Map<string, PendingToolCall>();
/** sessionKey → set of sockets belonging to MCP subprocesses for that session. */
const sessionSockets = new Map<string, Set<Socket>>();

let bridgeSocketServer: NetServer | null = null;
let bridgeSocketPath: string | null = null;

function socketPath(): string {
  return join(tmpdir(), `shiro-bridge-${process.pid}-${Date.now()}.sock`);
}

function startBridgeSocket(): Promise<string> {
  return new Promise((resolve, reject) => {
    const path = socketPath();
    if (existsSync(path)) {
      try { unlinkSync(path); } catch { /* ignore */ }
    }
    const server = createNetServer((socket) => {
      let buffer = "";
      let associatedSessionKey: string | null = null;

      socket.on("data", (chunk) => {
        buffer += chunk.toString("utf8");
        let nl;
        while ((nl = buffer.indexOf("\n")) >= 0) {
          const line = buffer.slice(0, nl);
          buffer = buffer.slice(nl + 1);
          if (!line.trim()) continue;
          let msg: PipeMessage;
          try {
            msg = JSON.parse(line) as PipeMessage;
          } catch {
            log("warn", `malformed pipe message: ${line.slice(0, 200)}`);
            continue;
          }
          if (msg.type === "tool_use") {
            const sk = msg.sessionKey ?? "main";
            associatedSessionKey = sk;
            if (!sessionSockets.has(sk)) sessionSockets.set(sk, new Set());
            sessionSockets.get(sk)!.add(socket);
            handlePipeToolUse(msg, socket);
          } else if (msg.type === "log") {
            log(msg.level, `[tools-stdio] ${msg.message}`);
          }
          // tool_result not expected inbound on this socket; it flows bridge → subprocess.
        }
      });

      socket.on("close", () => {
        if (associatedSessionKey) {
          sessionSockets.get(associatedSessionKey)?.delete(socket);
        }
        // Fail any pending calls that were waiting on this socket.
        for (const [callId, pending] of pendingToolCalls) {
          if (pending.socket === socket) {
            pendingToolCalls.delete(callId);
            // No reply is possible now; silent drop — the subprocess is gone.
          }
        }
      });

      socket.on("error", (err) => {
        log("warn", `socket client error: ${err.message}`);
      });
    });

    server.on("error", reject);
    server.listen(path, () => {
      bridgeSocketServer = server;
      bridgeSocketPath = path;
      log("info", `bridge socket listening at ${path}`);
      resolve(path);
    });
  });
}

function handlePipeToolUse(msg: PipeToolUseMessage, socket: Socket): void {
  const sessionKey = msg.sessionKey ?? "main";
  const session = sessionsByKey.get(sessionKey);
  const sessionId = session?.sessionId ?? "";

  pendingToolCalls.set(msg.callId, {
    socket,
    sessionKey,
    startedAt: Date.now(),
  });

  const riskLevel: ToolRiskLevel = msg.riskLevel ?? "high";

  send({
    type: "tool_activity",
    sessionId,
    sessionKey,
    name: msg.name,
    status: "started",
    toolUseId: msg.callId,
    input: msg.input,
  });
  send({
    type: "tool_use",
    sessionId,
    sessionKey,
    callId: msg.callId,
    name: msg.name,
    input: msg.input,
    riskLevel,
    justification: msg.justification,
  });
}

function handleToolResultFromSwift(msg: ToolResultMessage): void {
  const pending = pendingToolCalls.get(msg.callId);
  if (!pending) {
    log("warn", `tool_result for unknown callId ${msg.callId}`);
    return;
  }
  pendingToolCalls.delete(msg.callId);

  const sessionId = sessionsByKey.get(pending.sessionKey)?.sessionId ?? "";

  // Forward result down to the MCP subprocess.
  const payload = {
    type: "tool_result" as const,
    callId: msg.callId,
    result: msg.denied ? `Denied by user: ${msg.denialReason ?? "no reason given"}` : msg.result,
    isError: msg.isError === true || msg.denied === true,
  };
  try {
    pending.socket.write(JSON.stringify(payload) + "\n");
  } catch (err) {
    log("error", `failed to write result to tools-stdio socket: ${err}`);
  }

  send({
    type: "tool_activity",
    sessionId,
    sessionKey: pending.sessionKey,
    name: "",
    status: "completed",
    toolUseId: msg.callId,
  });
  send({
    type: "tool_result_display",
    sessionId,
    sessionKey: pending.sessionKey,
    toolUseId: msg.callId,
    name: "",
    output: payload.result,
    isError: payload.isError,
  });
}

// ---------------------------------------------------------------------------
// Session lifecycle  (Claude Agent SDK)
// ---------------------------------------------------------------------------

interface SessionState {
  sessionKey: string;
  sessionId: string;              // filled after first SDK message
  cwd: string;
  model?: string;
  systemPrompt?: string;
  abort: AbortController;
  running: boolean;
  /** mcp subprocess we spawned for this session's tools (if any). Null
   *  when we rely on SDK-managed stdio MCP (`mcpServers` config). */
  mcpChild: ChildProcess | null;
}

const sessionsByKey = new Map<string, SessionState>();

function ensureSession(sessionKey: string, cwd: string): SessionState {
  let s = sessionsByKey.get(sessionKey);
  if (s) return s;
  s = {
    sessionKey,
    sessionId: "",
    cwd,
    abort: new AbortController(),
    running: false,
    mcpChild: null,
  };
  sessionsByKey.set(sessionKey, s);
  return s;
}

function makeMcpEnv(sessionKey: string, mode: "ask" | "act"): Record<string, string> {
  if (!bridgeSocketPath) throw new Error("bridge socket not started");
  return {
    SHIRO_BRIDGE_SOCKET: bridgeSocketPath,
    SHIRO_SESSION_KEY: sessionKey,
    SHIRO_QUERY_MODE: mode,
    SHIRO_TOOL_TIMEOUT_MS: process.env.SHIRO_TOOL_TIMEOUT_MS ?? "120000",
  };
}

async function runQuery(
  session: SessionState,
  msg: QueryMessage,
): Promise<void> {
  if (session.running) {
    log("warn", `query arrived while session "${session.sessionKey}" still running; queuing not yet implemented — interrupting prior turn`);
    session.abort.abort();
    session.abort = new AbortController();
  }
  session.running = true;

  const mode = msg.mode ?? "act";
  const model = msg.model ?? session.model ?? "claude-sonnet-4-6";
  const cwd = msg.cwd ?? session.cwd ?? process.cwd();
  session.cwd = cwd;
  session.model = model;
  if (msg.systemPrompt) session.systemPrompt = msg.systemPrompt;

  // Lazy-load the SDK so startup stays fast when no query arrives yet.
  const { query } = await import("@anthropic-ai/claude-agent-sdk");

  const shiroEnv = makeMcpEnv(session.sessionKey, mode);

  try {
    const q = query({
      prompt: msg.prompt,
      options: {
        cwd,
        model,
        systemPrompt: session.systemPrompt,
        resume: msg.resume,
        abortController: session.abort,
        includePartialMessages: true,
        permissionMode: mode === "ask" ? "plan" : "default",
        mcpServers: {
          shiro: {
            type: "stdio",
            command: process.execPath,  // current Node binary
            args: [toolsStdioPath],
            env: shiroEnv,
          },
        },
        env: {
          ...(process.env as Record<string, string | undefined>),
          // Route SDK's Anthropic calls through our LM Studio proxy.
          ANTHROPIC_BASE_URL: process.env.ANTHROPIC_BASE_URL,
          ANTHROPIC_API_KEY: process.env.ANTHROPIC_API_KEY ?? "lm-studio",
        },
      } as Record<string, unknown>,
    });

    for await (const ev of q) {
      dispatchSdkEvent(session, ev as Record<string, unknown>);
      if (session.abort.signal.aborted) break;
    }
  } catch (err) {
    const errMsg = err instanceof Error ? err.message : String(err);
    log("error", `query failed for session "${session.sessionKey}": ${errMsg}`);
    send({
      type: "error",
      sessionKey: session.sessionKey,
      sessionId: session.sessionId,
      message: errMsg,
    });
  } finally {
    session.running = false;
  }
}

function dispatchSdkEvent(session: SessionState, ev: Record<string, unknown>): void {
  const evType = String(ev.type ?? "");

  // First non-system event usually carries session_id.
  const sid = ev.session_id as string | undefined;
  if (sid && !session.sessionId) {
    session.sessionId = sid;
    send({ type: "init", sessionKey: session.sessionKey, sessionId: sid });
  }

  const sessionId = session.sessionId;
  const sessionKey = session.sessionKey;

  switch (evType) {
    case "stream_event": {
      // Partial streaming — deltas.
      const inner = ev.event as Record<string, unknown> | undefined;
      if (!inner) return;
      const innerType = String(inner.type ?? "");
      if (innerType === "content_block_delta") {
        const delta = inner.delta as Record<string, unknown> | undefined;
        if (!delta) return;
        if (delta.type === "text_delta" && typeof delta.text === "string") {
          send({ type: "text_delta", sessionId, sessionKey, text: delta.text });
        } else if (delta.type === "thinking_delta" && typeof delta.thinking === "string") {
          send({ type: "thinking_delta", sessionId, sessionKey, text: delta.thinking });
        }
      } else if (innerType === "content_block_stop") {
        send({ type: "text_block_boundary", sessionId, sessionKey });
      }
      return;
    }

    case "assistant": {
      // Full assistant message — mostly redundant with stream_event but
      // carries tool_use blocks reliably. We surface tool_activity here
      // so the UI spinner is shown even if the user disabled partial
      // streaming.
      const message = ev.message as Record<string, unknown> | undefined;
      if (!message) return;
      const blocks = message.content as Record<string, unknown>[] | undefined;
      if (!Array.isArray(blocks)) return;
      for (const b of blocks) {
        if (b.type === "tool_use") {
          send({
            type: "tool_activity",
            sessionId,
            sessionKey,
            name: String(b.name ?? ""),
            status: "started",
            toolUseId: String(b.id ?? ""),
            input: (b.input as Record<string, unknown> | undefined) ?? {},
          });
        }
      }
      return;
    }

    case "result": {
      const subtype = String(ev.subtype ?? "");
      if (subtype === "success") {
        const usage = (ev.usage as Record<string, number> | undefined) ?? {};
        send({
          type: "result",
          sessionId,
          sessionKey,
          text: String(ev.result ?? ""),
          inputTokens: usage.input_tokens,
          outputTokens: usage.output_tokens,
          costUsd: typeof ev.total_cost_usd === "number" ? ev.total_cost_usd : undefined,
        });
      } else {
        send({
          type: "error",
          sessionId,
          sessionKey,
          message: String(ev.result ?? "unknown error"),
        });
      }
      return;
    }

    case "system":
    case "user":
      // Informational — not forwarded in MVP.
      return;

    default:
      // Silently drop unknown event types — the SDK may add more.
      return;
  }
}

// ---------------------------------------------------------------------------
// Inbound Swift messages
// ---------------------------------------------------------------------------

async function handleInbound(msg: InboundMessage): Promise<void> {
  switch (msg.type) {
    case "query": {
      const sessionKey = msg.sessionKey ?? "main";
      const session = ensureSession(sessionKey, msg.cwd ?? process.cwd());
      runQuery(session, msg).catch((err) => {
        log("error", `runQuery threw: ${err}`);
      });
      return;
    }

    case "tool_result":
      handleToolResultFromSwift(msg);
      return;

    case "approval_audit":
      log("info", `approval audit: ${msg.callId} ${msg.decision} via ${msg.channel}`);
      return;

    case "interrupt": {
      if (msg.sessionKey) {
        const s = sessionsByKey.get(msg.sessionKey);
        if (s?.running) s.abort.abort();
      } else {
        for (const s of sessionsByKey.values()) if (s.running) s.abort.abort();
      }
      return;
    }

    case "warmup": {
      for (const cfg of msg.sessions ?? []) {
        const s = ensureSession(cfg.key, msg.cwd ?? process.cwd());
        s.model = cfg.model;
        if (cfg.systemPrompt) s.systemPrompt = cfg.systemPrompt;
      }
      return;
    }

    case "resetSession": {
      const key = msg.sessionKey ?? "main";
      const s = sessionsByKey.get(key);
      if (s?.running) s.abort.abort();
      sessionsByKey.delete(key);
      return;
    }

    case "spawn_agent":
      spawnSubAgent(msg).catch((err) => {
        log("error", `spawn_agent failed: ${err}`);
      });
      return;

    case "stop":
      shutdown(0);
      return;
  }
}

async function spawnSubAgent(msg: SpawnAgentMessage): Promise<void> {
  const session = ensureSession(msg.sessionKey, msg.cwd ?? process.cwd());
  session.systemPrompt = msg.persona;
  session.model = msg.model ?? session.model;

  send({
    type: "agent_started",
    sessionId: session.sessionId,
    sessionKey: session.sessionKey,
    taskId: msg.taskId,
    persona: msg.persona,
  });

  const synthetic: QueryMessage = {
    type: "query",
    id: `spawn-${randomUUID()}`,
    prompt: msg.prompt,
    systemPrompt: msg.persona,
    sessionKey: msg.sessionKey,
    cwd: msg.cwd,
    mode: "act",
    model: msg.model,
  };

  try {
    await runQuery(session, synthetic);
    send({
      type: "agent_finished",
      sessionId: session.sessionId,
      sessionKey: session.sessionKey,
      taskId: msg.taskId,
      status: "completed",
      summary: "(see session transcript)",
    });
  } catch (err) {
    send({
      type: "agent_finished",
      sessionId: session.sessionId,
      sessionKey: session.sessionKey,
      taskId: msg.taskId,
      status: "failed",
      summary: err instanceof Error ? err.message : String(err),
    });
  }
}

// ---------------------------------------------------------------------------
// Shutdown
// ---------------------------------------------------------------------------

let shuttingDown = false;
function shutdown(code: number): void {
  if (shuttingDown) return;
  shuttingDown = true;
  log("info", `shutting down (code=${code})`);
  for (const s of sessionsByKey.values()) {
    try { s.abort.abort(); } catch { /* ignore */ }
    if (s.mcpChild && !s.mcpChild.killed) {
      try { s.mcpChild.kill("SIGTERM"); } catch { /* ignore */ }
    }
  }
  if (bridgeSocketServer) {
    try { bridgeSocketServer.close(); } catch { /* ignore */ }
  }
  if (bridgeSocketPath && existsSync(bridgeSocketPath)) {
    try { unlinkSync(bridgeSocketPath); } catch { /* ignore */ }
  }
  setTimeout(() => process.exit(code), 150);
}

process.on("SIGTERM", () => shutdown(0));
process.on("SIGINT", () => shutdown(0));
process.on("uncaughtException", (err) => {
  log("error", `uncaughtException: ${err.stack ?? err}`);
  shutdown(1);
});
process.on("unhandledRejection", (reason) => {
  log("error", `unhandledRejection: ${reason instanceof Error ? reason.stack : String(reason)}`);
});

// ---------------------------------------------------------------------------
// Boot
// ---------------------------------------------------------------------------

async function main(): Promise<void> {
  // 1. LM Studio proxy — claim a port, route SDK through it.
  const proxyPort = await startLMStudioProxy(0);
  process.env.ANTHROPIC_BASE_URL = `http://127.0.0.1:${proxyPort}`;
  process.env.ANTHROPIC_API_KEY = process.env.ANTHROPIC_API_KEY ?? "lm-studio";

  // 2. Bridge Unix socket — MCP subprocesses dial in here.
  await startBridgeSocket();

  // 3. Read Swift messages on stdin.
  const rl = createInterface({ input: process.stdin, terminal: false });
  rl.on("line", (line) => {
    if (!line.trim()) return;
    let msg: InboundMessage;
    try {
      msg = JSON.parse(line) as InboundMessage;
    } catch (err) {
      log("warn", `malformed inbound line: ${err}`);
      return;
    }
    handleInbound(msg).catch((err) => {
      log("error", `handleInbound threw: ${err}`);
    });
  });
  rl.on("close", () => shutdown(0));

  log("info", "shiro-acp-bridge ready");
}

main().catch((err) => {
  process.stderr.write(`[bridge] fatal: ${err}\n`);
  process.exit(1);
});
