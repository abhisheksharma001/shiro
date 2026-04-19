#!/usr/bin/env bash
# =============================================================================
# Shiro — first-run setup script
# Usage: ./setup.sh
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRIDGE_DIR="$REPO_ROOT/acp-bridge"
SHIRO_DIR="$HOME/.shiro"

# ─── colors ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

ok()   { echo -e "${GREEN}✓${RESET} $1"; }
warn() { echo -e "${YELLOW}⚠${RESET}  $1"; }
err()  { echo -e "${RED}✗${RESET} $1"; }
step() { echo -e "\n${CYAN}${BOLD}▸ $1${RESET}"; }

echo -e "${BOLD}"
cat <<'BANNER'
  ███████╗██╗  ██╗██╗██████╗  ██████╗
  ██╔════╝██║  ██║██║██╔══██╗██╔═══██╗
  ███████╗███████║██║██████╔╝██║   ██║
  ╚════██║██╔══██║██║██╔══██╗██║   ██║
  ███████║██║  ██║██║██║  ██║╚██████╔╝
  ╚══════╝╚═╝  ╚═╝╚═╝╚═╝  ╚═╝ ╚═════╝
  Local-first macOS AI Desktop Agent — Setup
BANNER
echo -e "${RESET}"

# ─── 1. Prerequisites ─────────────────────────────────────────────────────────
step "Checking prerequisites"

if ! command -v node &>/dev/null; then
    err "Node.js not found. Install via: brew install node"
    exit 1
fi
NODE_VER=$(node --version)
ok "Node.js $NODE_VER"

if ! command -v npm &>/dev/null; then
    err "npm not found (should ship with Node.js)"
    exit 1
fi
ok "npm $(npm --version)"

if ! xcode-select -p &>/dev/null; then
    warn "Xcode Command Line Tools not found. Run: xcode-select --install"
fi

# ─── 2. Build the Node bridge ─────────────────────────────────────────────────
step "Building ACP bridge (acp-bridge/)"

cd "$BRIDGE_DIR"

if [ ! -d node_modules ]; then
    echo "  Installing npm dependencies…"
    npm install --silent
    ok "npm install"
else
    ok "node_modules already present (skipping install)"
fi

echo "  Compiling TypeScript…"
npm run build
ok "Bridge compiled → acp-bridge/dist/"

cd "$REPO_ROOT"

# ─── 3. Create ~/.shiro config directories ────────────────────────────────────
step "Creating ~/.shiro config directories"

mkdir -p "$SHIRO_DIR/skills"
mkdir -p "$SHIRO_DIR/hooks"
ok "~/.shiro/ structure ready"

# ─── 4. Verify Swift package resolves ─────────────────────────────────────────
step "Verifying Swift Package.swift"

if ! command -v swift &>/dev/null; then
    warn "swift CLI not found — Xcode must be installed to build the app"
else
    echo "  Resolving Swift package dependencies…"
    swift package resolve 2>&1 | tail -3 || true
    ok "Swift package dependencies resolved"
fi

# ─── 5. Print Xcode setup instructions ───────────────────────────────────────
step "Xcode setup instructions"

BRIDGE_DIST="$BRIDGE_DIR/dist/index.js"

echo -e "
${BOLD}Open the project in Xcode:${RESET}
  open $REPO_ROOT/Package.swift

  (Xcode 15+ treats Package.swift as a full project — no .xcodeproj needed)

${BOLD}Step 1 — Assign Entitlements:${RESET}
  1. Click the top-level \"Shiro\" package in the Project Navigator
  2. Select the \"Shiro\" target under TARGETS
  3. Click \"Signing & Capabilities\" tab
  4. Under \"App Sandbox\", disable sandbox (it must be OFF for Node subprocess)
  5. In the file inspector for Package.swift, set:
       Entitlements File → Shiro.entitlements

  OR: in Build Settings search for \"Code Signing Entitlements\"
  Set it to: \$(SRCROOT)/Shiro.entitlements

${BOLD}Step 2 — Add Environment Variables to Scheme:${RESET}
  1. Product → Scheme → Edit Scheme (⌘<)
  2. Select \"Run\" → \"Arguments\" tab
  3. Under \"Environment Variables\" add:

${CYAN}  Name                        Value${RESET}
  ────────────────────────────────────────────────────────────────
  SHIRO_NODE_PATH             $(which node 2>/dev/null || echo '/opt/homebrew/bin/node')
  SHIRO_BRIDGE_PATH           $BRIDGE_DIST
  LM_STUDIO_URL               http://localhost:1234
  SHIRO_BRAIN_MODEL           google/gemma-4-26b-a4b
  SHIRO_FAST_MODEL            qwen/qwen3-8b
  SHIRO_VISION_MODEL          qwen/qwen2.5-vl-7b
  SHIRO_EMBED_MODEL           text-embedding-embeddinggemma-300m-qat

  (ANTHROPIC_API_KEY is optional — set it here OR via the in-app Settings → API Keys tab)

${BOLD}Step 3 — Build & Run:${RESET}
  Press ⌘R in Xcode. The app appears as a floating bar (top of screen).
  Click the ⚙ icon → API Keys to enter your Anthropic key if using BYOK.

${BOLD}Troubleshooting:${RESET}
  • \"Operation not permitted\" on screen capture → System Settings → Privacy → Screen Recording → add Shiro
  • \"Node not found\" → make sure SHIRO_NODE_PATH points to the correct node binary
  • LM Studio errors → start LM Studio, load a model, start local server (port 1234)
  • Bridge log → watch Xcode console for [bridge info/warn/error] lines
"

# ─── 6. Done ──────────────────────────────────────────────────────────────────
echo -e "${GREEN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "${GREEN}${BOLD}  Setup complete! Follow the Xcode steps above.${RESET}"
echo -e "${GREEN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
