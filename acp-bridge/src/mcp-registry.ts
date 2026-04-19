/**
 * MCP Registry — reads ~/.shiro/mcp.json and builds the mcpServers map
 * that gets passed to the Claude Agent SDK's query() call.
 *
 * Config format:
 * {
 *   "servers": [
 *     {
 *       "name":        "github",
 *       "command":     "npx",
 *       "args":        ["-y", "@modelcontextprotocol/server-github"],
 *       "env":         { "GITHUB_PERSONAL_ACCESS_TOKEN": "${GITHUB_PERSONAL_ACCESS_TOKEN}" },
 *       "enabled":     true,
 *       "description": "GitHub repos, issues, PRs"
 *     }
 *   ]
 * }
 *
 * Variable expansion: ${VAR_NAME} in `args` and `env` values is replaced
 * with the corresponding process.env value at load time. If the var is
 * missing, the placeholder is left as-is (server may fail to auth — that's
 * the user's problem).
 */

import { readFileSync, writeFileSync, mkdirSync, existsSync } from "fs";
import { homedir } from "os";
import { join } from "path";

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

export interface MCPServerConfig {
  name: string;
  command: string;
  args: string[];
  env: Record<string, string>;
  enabled: boolean;
  description?: string;
}

export interface MCPRegistryFile {
  servers: MCPServerConfig[];
}

/** Shape the Claude Agent SDK expects in mcpServers. */
export interface SDKMCPServer {
  type: "stdio";
  command: string;
  args: string[];
  env?: Record<string, string>;
}

// ---------------------------------------------------------------------------
// Defaults — written to disk on first run
// ---------------------------------------------------------------------------

const DEFAULT_CONFIG: MCPRegistryFile = {
  servers: [
    {
      name: "github",
      command: "npx",
      args: ["-y", "@modelcontextprotocol/server-github"],
      env: { GITHUB_PERSONAL_ACCESS_TOKEN: "${GITHUB_PERSONAL_ACCESS_TOKEN}" },
      enabled: true,
      description: "GitHub repositories, issues, PRs, code search",
    },
    {
      name: "context7",
      command: "npx",
      args: ["-y", "@upstash/context7-mcp@latest"],
      env: {},
      enabled: true,
      description: "Live library documentation — prevents hallucinated APIs",
    },
    {
      name: "filesystem",
      command: "npx",
      args: ["-y", "@modelcontextprotocol/server-filesystem", "${HOME}/Projects"],
      env: {},
      enabled: true,
      description: "Read/write ~/Projects files directly",
    },
    {
      name: "composio",
      command: "npx",
      args: ["-y", "composio-mcp"],
      env: { COMPOSIO_API_KEY: "${COMPOSIO_API_KEY}" },
      enabled: false,
      description: "250+ integrations (Gmail, Slack, Notion, Linear, …)",
    },
    {
      name: "huggingface",
      command: "npx",
      args: ["-y", "@huggingface/mcp-client"],
      env: { HF_TOKEN: "${HF_TOKEN}" },
      enabled: false,
      description: "HuggingFace Hub — model search, dataset access, spaces",
    },
  ],
};

// ---------------------------------------------------------------------------
// Config path
// ---------------------------------------------------------------------------

function configPath(): string {
  return join(homedir(), ".shiro", "mcp.json");
}

// ---------------------------------------------------------------------------
// Load / initialise
// ---------------------------------------------------------------------------

/**
 * Load the MCP registry from disk.
 * Creates the default config if the file doesn't exist yet.
 * Returns only enabled servers.
 */
export function loadRegistry(): MCPServerConfig[] {
  const path = configPath();

  if (!existsSync(path)) {
    try {
      mkdirSync(join(homedir(), ".shiro"), { recursive: true });
      writeFileSync(path, JSON.stringify(DEFAULT_CONFIG, null, 2), "utf8");
      process.stderr.write(`[mcp-registry] created default config at ${path}\n`);
    } catch (err) {
      process.stderr.write(`[mcp-registry] could not write default config: ${err}\n`);
      return [];
    }
  }

  try {
    const raw = readFileSync(path, "utf8");
    const parsed = JSON.parse(raw) as MCPRegistryFile;
    const servers = parsed.servers ?? [];

    // Drop servers that are explicitly disabled OR whose command is a
    // placeholder — those configs would cause an obvious spawn error
    // at query time. Better to skip loudly at load time.
    const PLACEHOLDER_COMMANDS = new Set(["unavailable", "placeholder", ""]);
    const enabled: MCPServerConfig[] = [];
    for (const s of servers) {
      if (s.enabled === false) continue;
      const cmd = (s.command ?? "").trim();
      if (PLACEHOLDER_COMMANDS.has(cmd.toLowerCase())) {
        process.stderr.write(`[mcp-registry] skipping server '${s.name}' — placeholder command '${cmd}'\n`);
        continue;
      }
      enabled.push(s);
    }
    process.stderr.write(`[mcp-registry] loaded ${enabled.length}/${servers.length} servers from ${path}\n`);
    return enabled;
  } catch (err) {
    process.stderr.write(`[mcp-registry] failed to load ${path}: ${err}\n`);
    return [];
  }
}

// ---------------------------------------------------------------------------
// Variable expansion
// ---------------------------------------------------------------------------

/** Replace ${VAR} in a string with process.env.VAR, falling back to the original placeholder. */
function expandVars(str: string): string {
  return str.replace(/\$\{([^}]+)\}/g, (match, varName: string) => {
    const val = process.env[varName];
    if (val !== undefined && val !== "") return val;
    // Leave placeholder in place — server will likely fail to auth; that's expected
    // when the user hasn't configured the env var yet.
    return match;
  });
}

function expandServer(server: MCPServerConfig): MCPServerConfig {
  return {
    ...server,
    args: server.args.map(expandVars),
    env: Object.fromEntries(
      Object.entries(server.env).map(([k, v]) => [k, expandVars(v)])
    ),
  };
}

// ---------------------------------------------------------------------------
// Build SDK mcpServers map
// ---------------------------------------------------------------------------

/**
 * Returns a map of `name → SDKMCPServer` ready to be spread into the
 * `mcpServers` option of the Claude Agent SDK `query()` call.
 *
 * Only enabled servers are included. Env vars are expanded.
 * Servers with missing required env vars (still containing ${…}) are
 * included anyway — they'll just fail at auth time with a clear error.
 */
export function buildMCPServersMap(): Record<string, SDKMCPServer> {
  const servers = loadRegistry();
  const map: Record<string, SDKMCPServer> = {};

  for (const server of servers) {
    const expanded = expandServer(server);
    map[expanded.name] = {
      type: "stdio",
      command: expanded.command,
      args: expanded.args,
      // Only pass env if it has entries — avoids passing empty {} to SDK
      ...(Object.keys(expanded.env).length > 0 ? { env: expanded.env } : {}),
    };
  }

  return map;
}
