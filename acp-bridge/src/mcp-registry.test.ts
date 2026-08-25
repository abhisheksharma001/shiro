/**
 * Tests for mcp-registry pure helpers: ${VAR} expansion and the
 * placeholder/disabled-server filter.
 *
 * Run via: npm test (compiles with tsc, then node --test dist/)
 */

import test from "node:test";
import assert from "node:assert/strict";
import { expandVars, filterEnabledServers, type MCPServerConfig } from "./mcp-registry.js";

// ---------------------------------------------------------------------------
// expandVars
// ---------------------------------------------------------------------------

test("expandVars replaces ${VAR} with the env value", () => {
  process.env.SHIRO_TEST_TOKEN = "abc123";
  assert.equal(expandVars("${SHIRO_TEST_TOKEN}"), "abc123");
  delete process.env.SHIRO_TEST_TOKEN;
});

test("expandVars expands multiple occurrences and mixes literal text", () => {
  process.env.SHIRO_TEST_A = "x";
  process.env.SHIRO_TEST_B = "y";
  assert.equal(
    expandVars("a=${SHIRO_TEST_A} b=${SHIRO_TEST_B} a again=${SHIRO_TEST_A}"),
    "a=x b=y a again=x"
  );
  delete process.env.SHIRO_TEST_A;
  delete process.env.SHIRO_TEST_B;
});

test("expandVars leaves the placeholder in place when the var is unset", () => {
  delete process.env.SHIRO_TEST_MISSING;
  assert.equal(expandVars("${SHIRO_TEST_MISSING}"), "${SHIRO_TEST_MISSING}");
});

test("expandVars treats an empty env value as unset (placeholder stays)", () => {
  process.env.SHIRO_TEST_EMPTY = "";
  assert.equal(expandVars("${SHIRO_TEST_EMPTY}"), "${SHIRO_TEST_EMPTY}");
  delete process.env.SHIRO_TEST_EMPTY;
});

test("expandVars passes through strings without placeholders", () => {
  assert.equal(expandVars("-y @modelcontextprotocol/server-github"), "-y @modelcontextprotocol/server-github");
});

// ---------------------------------------------------------------------------
// filterEnabledServers
// ---------------------------------------------------------------------------

function server(overrides: Partial<MCPServerConfig>): MCPServerConfig {
  return {
    name: "test",
    command: "npx",
    args: [],
    env: {},
    enabled: true,
    ...overrides,
  };
}

test("filterEnabledServers keeps enabled servers", () => {
  const out = filterEnabledServers([server({ name: "github" }), server({ name: "context7" })]);
  assert.deepEqual(out.map((s) => s.name), ["github", "context7"]);
});

test("filterEnabledServers drops explicitly disabled servers", () => {
  const out = filterEnabledServers([
    server({ name: "off", enabled: false }),
    server({ name: "on" }),
  ]);
  assert.deepEqual(out.map((s) => s.name), ["on"]);
});

test("filterEnabledServers drops placeholder commands (case-insensitive)", () => {
  const out = filterEnabledServers([
    server({ name: "a", command: "unavailable" }),
    server({ name: "b", command: "Placeholder" }),
    server({ name: "c", command: "" }),
    server({ name: "d", command: "  " }),
    server({ name: "ok", command: "npx" }),
  ]);
  assert.deepEqual(out.map((s) => s.name), ["ok"]);
});
