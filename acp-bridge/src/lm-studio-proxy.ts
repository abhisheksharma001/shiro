/**
 * LM Studio proxy — translates Anthropic Messages API ↔ OpenAI Chat
 * Completions so the Claude Agent SDK can talk to LM Studio (or any
 * OpenAI-compatible endpoint) transparently.
 *
 * The bridge sets ANTHROPIC_BASE_URL=http://127.0.0.1:<proxyPort> and
 * ANTHROPIC_API_KEY=lm-studio before spawning the ACP subprocess, so the
 * SDK's outbound requests land here.
 *
 * This file is intentionally stateless and small — it is the ONLY place
 * in the bridge that knows about OpenAI format. Everything else uses the
 * Anthropic message shape.
 */

import { createServer, type IncomingMessage, type ServerResponse } from "http";

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------

const LM_STUDIO_URL = process.env.LM_STUDIO_URL ?? "http://localhost:1234";

/** Maps Claude model aliases → the local model the user has loaded in LM
 *  Studio. Shiro's PLAN.md Section 3 defines the canonical roles:
 *    brain  → gemma-4-26b-a4b        (reasoning, planning)
 *    fast   → qwen/qwen3-8b          (chat, tool routing)
 *    vision → qwen/qwen2.5-vl-7b     (screen understanding)
 *  Override the whole map via SHIRO_MODEL_MAP (JSON) if the user wants a
 *  different model loaded. */
const DEFAULT_MODEL_MAP: Record<string, string> = {
  "claude-opus-4-6":            "google/gemma-4-26b-a4b",
  "claude-opus-4-5":            "google/gemma-4-26b-a4b",
  "claude-sonnet-4-6":          "qwen/qwen3-8b",
  "claude-sonnet-4-5":          "qwen/qwen3-8b",
  "claude-haiku-4-5":           "qwen/qwen3-8b",
  "claude-haiku-4-5-20251001":  "qwen/qwen3-8b",
  // Pass-through for direct local names
  "qwen/qwen3-8b":              "qwen/qwen3-8b",
  "qwen/qwen2.5-vl-7b":         "qwen/qwen2.5-vl-7b",
  "google/gemma-4-26b-a4b":     "google/gemma-4-26b-a4b",
};

function loadModelMap(): Record<string, string> {
  const raw = process.env.SHIRO_MODEL_MAP;
  if (!raw) return DEFAULT_MODEL_MAP;
  try {
    const parsed = JSON.parse(raw) as Record<string, string>;
    return { ...DEFAULT_MODEL_MAP, ...parsed };
  } catch {
    log("warn", `SHIRO_MODEL_MAP is not valid JSON, ignoring`);
    return DEFAULT_MODEL_MAP;
  }
}

const MODEL_MAP = loadModelMap();
const FALLBACK_MODEL = process.env.SHIRO_FALLBACK_MODEL ?? "qwen/qwen3-8b";

function resolveModel(requested: string): string {
  return MODEL_MAP[requested] ?? requested ?? FALLBACK_MODEL;
}

function log(level: "info" | "warn" | "error", msg: string): void {
  process.stderr.write(`[lm-proxy ${level}] ${msg}\n`);
}

// ---------------------------------------------------------------------------
// Format translation
// ---------------------------------------------------------------------------

type JSONObject = Record<string, unknown>;

/** Flatten an Anthropic content array down to a single text string for
 *  OpenAI's `messages[].content`. Tool_use / tool_result blocks are
 *  rendered into a minimal prose form so the local model can at least see
 *  the shape (LM Studio has no native tool-use path that maps 1:1). */
function flattenAnthropicContent(content: unknown): string {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  return content
    .map((block) => {
      const b = block as JSONObject;
      switch (b.type) {
        case "text":
          return typeof b.text === "string" ? b.text : "";
        case "tool_use":
          return `<tool_use name="${String(b.name)}" id="${String(b.id)}">${JSON.stringify(b.input ?? {})}</tool_use>`;
        case "tool_result":
          return `<tool_result id="${String(b.tool_use_id)}">${typeof b.content === "string" ? b.content : JSON.stringify(b.content ?? "")}</tool_result>`;
        default:
          return "";
      }
    })
    .filter(Boolean)
    .join("\n");
}

function anthropicToOpenAIRequest(body: JSONObject): JSONObject {
  const messages: JSONObject[] = [];

  // Anthropic's system prompt can be string or array-of-blocks; OpenAI wants
  // a single system message at the head.
  if (body.system != null) {
    const sys = typeof body.system === "string"
      ? body.system
      : flattenAnthropicContent(body.system);
    if (sys) messages.push({ role: "system", content: sys });
  }

  if (Array.isArray(body.messages)) {
    for (const m of body.messages) {
      const mm = m as JSONObject;
      const flat = flattenAnthropicContent(mm.content);
      if (!flat) continue;
      messages.push({ role: String(mm.role), content: flat });
    }
  }

  const resolved = resolveModel(String(body.model ?? ""));
  return {
    model: resolved,
    messages,
    max_tokens: body.max_tokens ?? 2048,
    temperature: body.temperature ?? 0.7,
    top_p: body.top_p ?? 1,
    stream: body.stream === true,
  };
}

function openaiToAnthropicResponse(oai: JSONObject, model: string): JSONObject {
  const choices = (oai.choices as JSONObject[] | undefined) ?? [];
  const first = (choices[0] ?? {}) as JSONObject;
  const message = (first.message ?? {}) as JSONObject;
  // Some local models (qwen3 with thinking mode) put output into
  // `reasoning_content` when `content` is empty. Fall back gracefully.
  const text =
    (typeof message.content === "string" && message.content) ||
    (typeof message.reasoning_content === "string" && message.reasoning_content) ||
    "";
  const usage = (oai.usage as JSONObject | undefined) ?? {};
  const stopReason = first.finish_reason === "stop" ? "end_turn" : (first.finish_reason ?? "end_turn");

  return {
    id: oai.id ?? `msg_${Date.now()}`,
    type: "message",
    role: "assistant",
    model,
    content: [{ type: "text", text }],
    stop_reason: stopReason,
    stop_sequence: null,
    usage: {
      input_tokens: (usage.prompt_tokens as number | undefined) ?? 0,
      output_tokens: (usage.completion_tokens as number | undefined) ?? 0,
      cache_read_input_tokens: 0,
      cache_creation_input_tokens: 0,
    },
  };
}

/** Convert one OpenAI streaming chunk into zero-or-more Anthropic SSE
 *  events. Caller is responsible for emitting message_start on chunk 0. */
function streamChunkToAnthropic(
  chunk: JSONObject,
  model: string,
  isFirst: boolean,
): string {
  const choices = (chunk.choices as JSONObject[] | undefined) ?? [];
  const first = (choices[0] ?? {}) as JSONObject;
  const delta = (first.delta as JSONObject | undefined) ?? {};
  const text =
    (typeof delta.content === "string" && delta.content) ||
    (typeof delta.reasoning_content === "string" && delta.reasoning_content) ||
    "";
  const finishReason = first.finish_reason;
  const events: string[] = [];

  if (isFirst) {
    events.push(
      `event: message_start\ndata: ${JSON.stringify({
        type: "message_start",
        message: {
          id: chunk.id ?? `msg_${Date.now()}`,
          type: "message",
          role: "assistant",
          model,
          content: [],
          stop_reason: null,
          stop_sequence: null,
          usage: { input_tokens: 0, output_tokens: 0, cache_read_input_tokens: 0, cache_creation_input_tokens: 0 },
        },
      })}\n`,
    );
    events.push(
      `event: content_block_start\ndata: ${JSON.stringify({
        type: "content_block_start",
        index: 0,
        content_block: { type: "text", text: "" },
      })}\n`,
    );
  }

  if (text) {
    events.push(
      `event: content_block_delta\ndata: ${JSON.stringify({
        type: "content_block_delta",
        index: 0,
        delta: { type: "text_delta", text },
      })}\n`,
    );
  }

  if (finishReason) {
    events.push(
      `event: content_block_stop\ndata: ${JSON.stringify({
        type: "content_block_stop",
        index: 0,
      })}\n`,
    );
    events.push(
      `event: message_delta\ndata: ${JSON.stringify({
        type: "message_delta",
        delta: { stop_reason: "end_turn", stop_sequence: null },
        usage: { output_tokens: 0 },
      })}\n`,
    );
    events.push(
      `event: message_stop\ndata: ${JSON.stringify({ type: "message_stop" })}\n`,
    );
    events.push("data: [DONE]\n");
  }

  return events.join("\n");
}

// ---------------------------------------------------------------------------
// HTTP server
// ---------------------------------------------------------------------------

async function readRequestBody(req: IncomingMessage): Promise<string> {
  return new Promise((resolve, reject) => {
    const chunks: Buffer[] = [];
    req.on("data", (c: Buffer) => chunks.push(c));
    req.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
    req.on("error", reject);
  });
}

async function handleMessages(
  req: IncomingMessage,
  res: ServerResponse,
): Promise<void> {
  const rawBody = await readRequestBody(req);
  let anthropicReq: JSONObject;
  try {
    anthropicReq = JSON.parse(rawBody) as JSONObject;
  } catch (err) {
    log("error", `invalid JSON body: ${err}`);
    res.writeHead(400, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ error: { type: "invalid_request_error", message: "Malformed JSON body" } }));
    return;
  }

  const requestedModel = String(anthropicReq.model ?? "");
  const model = resolveModel(requestedModel);
  const isStream = anthropicReq.stream === true;
  if (requestedModel !== model) {
    log("info", `model remap: ${requestedModel} → ${model}`);
  }

  const openaiReq = anthropicToOpenAIRequest(anthropicReq);

  let upstream: Response;
  try {
    upstream = await fetch(`${LM_STUDIO_URL}/v1/chat/completions`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: "Bearer lm-studio",
      },
      body: JSON.stringify(openaiReq),
    });
  } catch (err) {
    log("error", `upstream fetch failed: ${err}`);
    res.writeHead(502, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ error: { type: "upstream_error", message: String(err) } }));
    return;
  }

  if (!upstream.ok) {
    const errBody = await upstream.text();
    log("error", `LM Studio ${upstream.status}: ${errBody}`);
    res.writeHead(upstream.status, { "Content-Type": "application/json" });
    res.end(errBody);
    return;
  }

  if (isStream && upstream.body) {
    res.writeHead(200, {
      "Content-Type": "text/event-stream",
      "Cache-Control": "no-cache",
      Connection: "keep-alive",
    });
    const reader = upstream.body.getReader();
    const decoder = new TextDecoder();
    let buffer = "";
    let chunkIdx = 0;
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      buffer += decoder.decode(value, { stream: true });
      let nl;
      while ((nl = buffer.indexOf("\n")) >= 0) {
        const line = buffer.slice(0, nl).trim();
        buffer = buffer.slice(nl + 1);
        if (!line.startsWith("data:")) continue;
        const payload = line.slice(5).trim();
        if (payload === "[DONE]") {
          res.end();
          return;
        }
        try {
          const chunk = JSON.parse(payload) as JSONObject;
          const events = streamChunkToAnthropic(chunk, model, chunkIdx === 0);
          chunkIdx += 1;
          if (events) res.write(events + "\n");
        } catch {
          // malformed chunk — skip
        }
      }
    }
    res.end();
    return;
  }

  const oaiResp = (await upstream.json()) as JSONObject;
  const anthropicResp = openaiToAnthropicResponse(oaiResp, model);
  const usage = anthropicResp.usage as { input_tokens: number; output_tokens: number };
  log("info", `← ${model} in=${usage.input_tokens} out=${usage.output_tokens}`);
  res.writeHead(200, { "Content-Type": "application/json" });
  res.end(JSON.stringify(anthropicResp));
}

async function handlePassthrough(
  req: IncomingMessage,
  res: ServerResponse,
): Promise<void> {
  const url = req.url ?? "/";
  try {
    const upstream = await fetch(`${LM_STUDIO_URL}${url}`, {
      method: req.method,
      headers: {
        "Content-Type": "application/json",
        Authorization: "Bearer lm-studio",
      },
    });
    const body = await upstream.text();
    res.writeHead(upstream.status, { "Content-Type": upstream.headers.get("Content-Type") ?? "application/json" });
    res.end(body);
  } catch (err) {
    log("error", `passthrough ${url} failed: ${err}`);
    res.writeHead(502, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ error: { type: "upstream_error", message: String(err) } }));
  }
}

export async function startLMStudioProxy(port = 0): Promise<number> {
  return new Promise((resolve, reject) => {
    const server = createServer((req, res) => {
      const url = req.url ?? "/";
      if (url.includes("/messages")) {
        handleMessages(req, res).catch((err) => {
          log("error", `unhandled messages error: ${err}`);
          if (!res.headersSent) {
            res.writeHead(500, { "Content-Type": "application/json" });
            res.end(JSON.stringify({ error: { type: "proxy_error", message: String(err) } }));
          }
        });
      } else {
        handlePassthrough(req, res).catch((err) => {
          log("error", `unhandled passthrough error: ${err}`);
          if (!res.headersSent) {
            res.writeHead(500, { "Content-Type": "application/json" });
            res.end(JSON.stringify({ error: { type: "proxy_error", message: String(err) } }));
          }
        });
      }
    });

    server.on("error", reject);
    server.listen(port, "127.0.0.1", () => {
      const addr = server.address();
      if (typeof addr !== "object" || addr === null) {
        reject(new Error("proxy: invalid listen address"));
        return;
      }
      log("info", `listening on http://127.0.0.1:${addr.port} → ${LM_STUDIO_URL}`);
      resolve(addr.port);
    });
  });
}
