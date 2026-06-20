# Shiro Remote Access — Setup Guide

Access Shiro from your iPhone using Telegram (zero setup) or iOS Shortcuts via Tailscale (voice support).

---

## Option A — Telegram (recommended, zero infra)

Already wired. Just configure your bot token in Settings → API Keys.

**Commands:**
```
/start          — welcome + command list
/status         — current model + task state
/model sonnet   — switch to claude-sonnet-4-6
/model opus     — switch to claude-opus-4-6
/model haiku    — switch to claude-haiku-4-5
/cancel         — stop running task
/code <task>    — plan + execute Claude Code task
/repos          — list your GitHub repos
/clone slug     — clone owner/repo to ~/Projects
```

Any free-text message runs through the agent and streams back.

---

## Option B — iOS Shortcuts + Tailscale (voice / widgets)

### 1. Install Tailscale

**Mac:**
```bash
brew install --cask tailscale
open -a Tailscale   # sign in, enable
```

**iPhone:** Install Tailscale from the App Store, sign in with the same account.

Get your Mac's Tailscale IP:
```bash
tailscale ip -4
# e.g. 100.64.1.2
```

### 2. Enable the HTTP server

Open Shiro → Settings → Remote tab → toggle **Enable server**.

Note your bearer token (click Show, then Copy).

### 3. Test from your phone

In a browser or Shortcuts, hit:
```
GET http://<tailscale-ip>:7421/v1/status
Authorization: Bearer <your-token>
```

Expected response: `{"running":false,"model":"default","queue":0}`

### 4. Create the iOS Shortcut

1. Open **Shortcuts** on iPhone → tap **+** → **New Shortcut**
2. Add action: **Dictate Text** → tap ✓ → stores in `Dictated Text`
3. Add action: **Get Contents of URL**
   - URL: `http://<tailscale-ip>:7421/v1/prompt`
   - Method: **POST**
   - Headers: `Authorization` → `Bearer <your-token>`
   - Headers: `Content-Type` → `application/json`
   - Request Body: **JSON**
     - Key: `text` → Value: `Dictated Text` (variable)
     - Key: `sync` → Value: `true`
4. Add action: **Get Dictionary Value** → Key: `text` → from **Contents of URL**
5. Add action: **Speak Text** → input: result from step 4

Name it **Ask Shiro**. Add to Home Screen.

**Usage:** Tap → speak → hear reply in ~5s.

### 5. Add a Siri Phrase (optional)

In the Shortcut: tap the title → **Add to Siri** → record "Ask Shiro".
Then: *"Hey Siri, Ask Shiro"* → speak → hear reply.

---

## Security notes

- The server binds to `127.0.0.1` only. It is **not** exposed to your LAN or internet.
- Tailscale's WireGuard tunnel makes your Mac's Tailscale IP reachable from your iPhone while keeping it invisible to everyone else.
- Rotate the bearer token any time via Settings → Remote → Rotate.
- Never share your token or commit it to git.

---

## Wake / Reachability

| Scenario | Works? |
|---|---|
| Mac awake, screen locked | ✅ Shiro process stays alive |
| Mac screen saver | ✅ Works fine |
| Mac in full sleep | ❌ Process suspended — WoL possible but not built-in |

To keep Mac awake during a long remote task:
```bash
caffeinate -d -t 3600   # keep display on for 1 hour
```
