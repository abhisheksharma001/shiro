/**
 * shiro-tools-stdio — MCP server spawned as a subprocess by the ACP agent.
 *
 * Speaks JSON-RPC 2.0 (MCP flavor) over stdin/stdout. Every tool call is
 * forwarded to the parent acp-bridge process over a Unix domain socket
 * whose path is passed in SHIRO_BRIDGE_SOCKET. The parent forwards to
 * Swift over its own stdio. Swift applies the Consent Gate (risk-based
 * approval, optionally via Telegram), executes, and replies.
 *
 * This is intentionally thin: NO business logic lives here. Every tool
 * is a shim that tags a risk level and hands off to Swift.
 */

import { createInterface } from "readline";
import { createConnection, type Socket } from "net";
import type {
  PipeMessage,
  PipeToolResultMessage,
  ToolRiskLevel,
} from "./protocol.js";

// ---------------------------------------------------------------------------
// Parent-bridge socket (Unix domain)
// ---------------------------------------------------------------------------

const SOCKET_PATH = process.env.SHIRO_BRIDGE_SOCKET;
const SESSION_KEY = process.env.SHIRO_SESSION_KEY;
const QUERY_MODE = (process.env.SHIRO_QUERY_MODE === "ask" ? "ask" : "act") as "ask" | "act";
const TOOL_TIMEOUT_MS = Number(process.env.SHIRO_TOOL_TIMEOUT_MS ?? 120_000);

let socket: Socket | null = null;
let socketReady = false;
let socketBuffer = "";

interface Pending {
  resolve: (msg: PipeToolResultMessage) => void;
  reject: (err: Error) => void;
  timer: ReturnType<typeof setTimeout>;
}
const pending = new Map<string, Pending>();

function logErr(level: "info" | "warn" | "error", msg: string): void {
  const line = `[shiro-tools-stdio ${level}] ${msg}\n`;
  if (socket && socketReady) {
    const payload: PipeMessage = { type: "log", level, message: msg };
    try {
      socket.write(JSON.stringify(payload) + "\n");
      return;
    } catch {
      // fall through to stderr
    }
  }
  process.stderr.write(line);
}

function connectSocket(): Promise<void> {
  return new Promise((resolve, reject) => {
    if (!SOCKET_PATH) {
      reject(new Error("SHIRO_BRIDGE_SOCKET env not set"));
      return;
    }
    socket = createConnection(SOCKET_PATH, () => {
      socketReady = true;
      logErr("info", `connected to bridge socket at ${SOCKET_PATH}`);
      resolve();
    });
    socket.on("data", (chunk: Buffer) => {
      socketBuffer += chunk.toString("utf8");
      let nl;
      while ((nl = socketBuffer.indexOf("\n")) >= 0) {
        const line = socketBuffer.slice(0, nl);
        socketBuffer = socketBuffer.slice(nl + 1);
        if (!line.trim()) continue;
        handleSocketLine(line);
      }
    });
    socket.on("error", (err) => {
      logErr("error", `socket error: ${err.message}`);
      if (!socketReady) reject(err);
      else {
        socketReady = false;
        failAllPending("bridge socket error");
      }
    });
    socket.on("close", () => {
      logErr("warn", "bridge socket closed");
      socketReady = false;
      failAllPending("bridge socket closed");
    });
  });
}

function handleSocketLine(line: string): void {
  let msg: PipeMessage;
  try {
    msg = JSON.parse(line) as PipeMessage;
  } catch {
    logErr("warn", `malformed socket line: ${line.slice(0, 200)}`);
    return;
  }
  if (msg.type === "tool_result") {
    const p = pending.get(msg.callId);
    if (!p) return;
    pending.delete(msg.callId);
    clearTimeout(p.timer);
    p.resolve(msg);
  }
}

function failAllPending(reason: string): void {
  for (const [callId, p] of pending) {
    clearTimeout(p.timer);
    p.resolve({
      type: "tool_result",
      callId,
      result: `Error: ${reason}`,
      isError: true,
    });
  }
  pending.clear();
}

let callIdCounter = 0;
function nextCallId(): string {
  callIdCounter += 1;
  return `shiro-${callIdCounter}-${Date.now()}`;
}

async function forwardToSwift(
  name: string,
  input: Record<string, unknown>,
  riskLevel: ToolRiskLevel,
  justification?: string,
): Promise<PipeToolResultMessage> {
  if (!socket || !socketReady) {
    return {
      type: "tool_result",
      callId: "",
      result: "Error: not connected to bridge socket",
      isError: true,
    };
  }
  const callId = nextCallId();
  return new Promise<PipeToolResultMessage>((resolve) => {
    const timer = setTimeout(() => {
      if (pending.has(callId)) {
        pending.delete(callId);
        logErr("warn", `tool ${name} timed out after ${TOOL_TIMEOUT_MS}ms`);
        resolve({
          type: "tool_result",
          callId,
          result: `Error: tool ${name} timed out after ${TOOL_TIMEOUT_MS / 1000}s`,
          isError: true,
        });
      }
    }, TOOL_TIMEOUT_MS);

    pending.set(callId, {
      resolve,
      reject: () => { /* resolve-only path */ },
      timer,
    });

    const msg = {
      type: "tool_use" as const,
      callId,
      name,
      input,
      sessionKey: SESSION_KEY,
      riskLevel,
      justification,
    };
    socket!.write(JSON.stringify(msg) + "\n");
  });
}

// ---------------------------------------------------------------------------
// Tool catalog — minimal MVP set
// ---------------------------------------------------------------------------

interface ToolDef {
  name: string;
  description: string;
  inputSchema: Record<string, unknown>;
  risk: ToolRiskLevel;
  /** If true, the tool is blocked whenever QUERY_MODE === "ask". */
  mutates: boolean;
}

const TOOLS: ToolDef[] = [
  {
    name: "execute_sql",
    description: [
      "Run SQL against the local shiro.db SQLite database.",
      "SELECT is auto-limited to 500 rows. UPDATE/DELETE require a WHERE clause.",
      "DROP / ALTER / CREATE / ATTACH are blocked here — use a migration instead.",
      "Use for: tasks, observations, meeting transcripts, KG queries, any structured data.",
    ].join(" "),
    inputSchema: {
      type: "object",
      properties: {
        query: { type: "string", description: "SQL to execute." },
        description: { type: "string", description: "Human-readable summary (shown on approval card for writes)." },
      },
      required: ["query"],
    },
    risk: "med",  // SELECT = low, write = high; Swift upgrades per query shape
    mutates: true,
  },
  {
    name: "capture_screenshot",
    description: [
      "Take a screenshot of the user's screen or a specific window.",
      "Returns a base64 JPEG via an `image` content block. Use when the user asks what's on screen,",
      "for visual debugging, or before a macOS automation action.",
    ].join(" "),
    inputSchema: {
      type: "object",
      properties: {
        mode: { type: "string", enum: ["screen", "window"], description: "`screen` = full display, `window` = frontmost app." },
      },
      required: [],
    },
    risk: "low",
    mutates: false,
  },
  {
    name: "query_kg",
    description: [
      "Query Shiro's knowledge graph. Args: { nodeType?, query?, limit? }.",
      "Returns JSON array of nodes with their edges. Use to recall people, projects, files, meetings.",
    ].join(" "),
    inputSchema: {
      type: "object",
      properties: {
        nodeType: { type: "string", description: "Filter by node type (person | project | file | meeting | task | skill)." },
        query: { type: "string", description: "Substring match against node name/body." },
        limit: { type: "number", description: "Max results (default 25, max 200)." },
      },
      required: [],
    },
    risk: "low",
    mutates: false,
  },
  {
    name: "search_memory",
    description: [
      "Hybrid vector + FTS search across Shiro's memory (code, docs, papers, meetings, screen history).",
      "Args: { query, corpora?, k? }. Returns ranked passages with source + timestamp.",
      "Use this FIRST before asking the user to re-explain something.",
    ].join(" "),
    inputSchema: {
      type: "object",
      properties: {
        query: { type: "string", description: "Natural-language query." },
        corpora: { type: "array", items: { type: "string" }, description: "Subset: code | papers | meetings | screen | chat | skills | kg (omit = all)." },
        k: { type: "number", description: "Top-k results (default 8, max 40)." },
      },
      required: ["query"],
    },
    risk: "low",
    mutates: false,
  },
  {
    name: "file_read",
    description: "Read a file from disk. Absolute paths only. Returns file content as text.",
    inputSchema: {
      type: "object",
      properties: {
        path: { type: "string", description: "Absolute file path." },
        offset: { type: "number", description: "Start line (1-indexed)." },
        limit: { type: "number", description: "Max lines to return." },
      },
      required: ["path"],
    },
    risk: "low",
    mutates: false,
  },
  {
    name: "file_write",
    description: "Write a file to disk. Overwrites. Absolute path required. HIGH risk — requires user approval.",
    inputSchema: {
      type: "object",
      properties: {
        path: { type: "string", description: "Absolute destination path." },
        content: { type: "string", description: "Full file contents." },
        description: { type: "string", description: "One-line reason for this write." },
      },
      required: ["path", "content"],
    },
    risk: "high",
    mutates: true,
  },
  {
    name: "shell_exec",
    description: [
      "Run a shell command and return stdout/stderr. Uses /bin/zsh. 60s timeout.",
      "HIGH risk — user must approve every invocation unless explicitly whitelisted.",
      "Use sparingly; prefer dedicated tools when available.",
    ].join(" "),
    inputSchema: {
      type: "object",
      properties: {
        command: { type: "string", description: "Shell command line." },
        cwd: { type: "string", description: "Working directory (absolute)." },
        description: { type: "string", description: "Why you need to run this. Shown on the approval card." },
      },
      required: ["command"],
    },
    risk: "high",
    mutates: true,
  },
  {
    name: "macos_action",
    description: [
      "Drive the macOS UI via Accessibility (AXUI) or AppleScript.",
      "Args: { action: click|type|key|open_app|reveal_file, target, value? }. HIGH risk.",
      "Always explain in `description` what you intend to do — user approval is mandatory.",
    ].join(" "),
    inputSchema: {
      type: "object",
      properties: {
        action: { type: "string", enum: ["click", "type", "key", "open_app", "reveal_file"] },
        target: { type: "string", description: "AXUI selector, app bundle id, or file path." },
        value: { type: "string", description: "Text/key to send (for type/key actions)." },
        description: { type: "string", description: "Why. Shown on approval card." },
      },
      required: ["action", "target"],
    },
    risk: "high",
    mutates: true,
  },
  {
    name: "spawn_subagent",
    description: [
      "Delegate a subtask to a fresh agent with its own persona and budget.",
      "Args: { taskId, persona, prompt, model?, costBudgetUsd?, depthBudget? }.",
      "Returns the subagent's sessionKey. Subagent runs in parallel; poll `query_kg` or `search_memory` for results, or wait on an `agent_finished` notification.",
    ].join(" "),
    inputSchema: {
      type: "object",
      properties: {
        taskId: { type: "string", description: "Stable id for this subtask (used for atomic SQL checkout)." },
        persona: { type: "string", description: "System prompt for the subagent." },
        prompt: { type: "string", description: "The actual task description." },
        model: { type: "string", description: "Optional model override." },
        costBudgetUsd: { type: "number", description: "Hard cost cap; subagent is killed on breach." },
        depthBudget: { type: "number", description: "Max nested spawn depth (default 2)." },
      },
      required: ["taskId", "persona", "prompt"],
    },
    risk: "med",
    mutates: false,
  },
  {
    name: "ask_followup",
    description: "Ask the user a clarifying question. Returns their answer. Prefer specific single questions.",
    inputSchema: {
      type: "object",
      properties: {
        question: { type: "string", description: "The question to ask." },
        suggestions: { type: "array", items: { type: "string" }, description: "Optional one-click reply chips." },
      },
      required: ["question"],
    },
    risk: "low",
    mutates: false,
  },
];

// ---------------------------------------------------------------------------
// JSON-RPC (MCP) dispatch
// ---------------------------------------------------------------------------

function sendRpc(msg: Record<string, unknown>): void {
  process.stdout.write(JSON.stringify(msg) + "\n");
}

function rpcError(id: unknown, code: number, message: string): void {
  sendRpc({ jsonrpc: "2.0", id, error: { code, message } });
}

async function handleToolCall(
  id: unknown,
  name: string,
  args: Record<string, unknown>,
  isNotification: boolean,
): Promise<void> {
  const def = TOOLS.find((t) => t.name === name);
  if (!def) {
    if (!isNotification) rpcError(id, -32601, `Unknown tool: ${name}`);
    return;
  }

  // Enforce ask-mode: block any mutating tool.
  if (QUERY_MODE === "ask" && def.mutates) {
    if (!isNotification) {
      sendRpc({
        jsonrpc: "2.0",
        id,
        result: {
          content: [{ type: "text", text: `Blocked: tool \`${name}\` mutates state; current session is in Ask mode (read-only).` }],
          isError: true,
        },
      });
    }
    return;
  }

  // Risk refinement: execute_sql is "low" when it's a SELECT, else "high".
  let effectiveRisk = def.risk;
  if (name === "execute_sql") {
    const q = String(args.query ?? "").trim().toUpperCase();
    effectiveRisk = q.startsWith("SELECT") || q.startsWith("WITH") ? "low" : "high";
  }

  const justification = typeof args.description === "string" ? args.description : undefined;
  const result = await forwardToSwift(name, args, effectiveRisk, justification);

  if (isNotification) return;

  // Screenshot special-case: surface base64 as an image block if we got one.
  if (name === "capture_screenshot" && !result.isError && result.result.length > 0 && !result.result.startsWith("ERROR:")) {
    sendRpc({
      jsonrpc: "2.0",
      id,
      result: {
        content: [
          { type: "image", data: result.result, mimeType: "image/jpeg" },
          { type: "text", text: `Screenshot captured (${String(args.mode ?? "screen")}).` },
        ],
      },
    });
    return;
  }

  sendRpc({
    jsonrpc: "2.0",
    id,
    result: {
      content: [{ type: "text", text: result.result }],
      isError: result.isError === true,
    },
  });
}

async function handleRpc(body: Record<string, unknown>): Promise<void> {
  const id = body.id;
  const method = String(body.method ?? "");
  const params = (body.params as Record<string, unknown> | undefined) ?? {};
  const isNotification = id === undefined || id === null;

  switch (method) {
    case "initialize":
      if (!isNotification) {
        sendRpc({
          jsonrpc: "2.0",
          id,
          result: {
            protocolVersion: "2024-11-05",
            capabilities: { tools: {} },
            serverInfo: { name: "shiro_tools", version: "0.1.0" },
          },
        });
      }
      return;

    case "notifications/initialized":
    case "notifications/cancelled":
      return;

    case "tools/list":
      if (!isNotification) {
        sendRpc({
          jsonrpc: "2.0",
          id,
          result: {
            tools: TOOLS.map((t) => ({
              name: t.name,
              description: t.description,
              inputSchema: t.inputSchema,
            })),
          },
        });
      }
      return;

    case "tools/call": {
      const toolName = String(params.name ?? "");
      const args = (params.arguments as Record<string, unknown> | undefined) ?? {};
      await handleToolCall(id, toolName, args, isNotification);
      return;
    }

    default:
      if (!isNotification) rpcError(id, -32601, `Method not found: ${method}`);
  }
}

// ---------------------------------------------------------------------------
// Entry
// ---------------------------------------------------------------------------

async function main(): Promise<void> {
  try {
    await connectSocket();
  } catch (err) {
    process.stderr.write(`[shiro-tools-stdio] cannot connect to bridge: ${err}\n`);
    process.exit(1);
  }

  const rl = createInterface({ input: process.stdin, terminal: false });
  rl.on("line", (line: string) => {
    if (!line.trim()) return;
    let body: Record<string, unknown>;
    try {
      body = JSON.parse(line) as Record<string, unknown>;
    } catch (err) {
      logErr("warn", `malformed JSON-RPC line: ${err}`);
      return;
    }
    handleRpc(body).catch((err) => {
      logErr("error", `RPC handler threw: ${err}`);
      if (body.id !== undefined && body.id !== null) {
        rpcError(body.id, -32603, `Internal error: ${err instanceof Error ? err.message : String(err)}`);
      }
    });
  });

  rl.on("close", () => {
    logErr("info", "stdin closed, exiting");
    process.exit(0);
  });
}

main().catch((err) => {
  process.stderr.write(`[shiro-tools-stdio] fatal: ${err}\n`);
  process.exit(1);
});
