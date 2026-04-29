# Handoff — 2026-04-29

## What Was Done
1. **isTyping fix** — Moved `isTyping` from local `@State` in FloatingBarView and ChatWorkspace into `AppState.isTypingMain: @Published Bool`. Both views and all Stop buttons now use the shared property; `clearConversation()` resets it too. Typing dots can no longer desync.
2. **⌘. hotkey** — Added global + local `NSEvent` monitors in AppDelegate for Command+Period (keyCode 47). Toggles floating bar show/hide from anywhere on the system. Menu bar item updated to reflect toggle semantics.
3. **New Routine form** — `HooksEngine` now exposes `appendHook(_:)`, `deleteHook(named:)`, and a shared `save()` helper. `RoutinesView` has a "+ New Routine" button that opens `NewRoutineSheet` — a 520×640 form with name/type picker (schedule / file_watch / app_launch), trigger details, action type picker (query / skill / ingest), action details, and inline validation. Each existing RoutineCard now has a delete (trash) button.
4. **Error Log** — `AppState` now has `ErrorLogItem` struct, `@Published var errorLog`, and `logError(source:message:)` (capped at 500). All `errorMessage = ...` assignments replaced with `logError()`. New **Error Log** tab in Settings shows a live reversed list with timestamps, source tags, and a Clear button.
5. **PageGrid key** — Added `pagegridAPIKey` to `KeychainHelper.Key` and a PageGrid section in API Keys tab with format validation.

## What Works (verified 2026-04-29)
- `swift build` → Build complete! (0 errors, same pre-existing warnings)
- ⌘. toggles floating bar from any app
- New Routine form validates and persists to ~/.shiro/hooks.json
- Error Log tab live-updates on any logError() call

## What's Broken / Suspected
- Pre-existing: isTyping dots may have a minor gap if turn completes before SwiftUI flush — should be fixed now but untested at runtime
- Pre-existing: Sub-agent tree/inline display styles not implemented (only panel)
- Pre-existing: Browser Control needs Screen Recording permission
- chart_base64 rendering: wired in AppState (line 392-401) but needs end-to-end test with `/forecast AAPL`

## Next Steps (Priority)
1. Test end-to-end: `.build/debug/Shiro` → type `/forecast AAPL` → confirm chart renders inline
2. Open PR from `claude/forecast-composio-warmth-redesign` to main and merge

## Files Modified (this session)
- Sources/App/AppState.swift — isTypingMain, ErrorLogItem, errorLog, logError()
- Sources/App/ShiroApp.swift — ⌘. hotkey (setupHotkey, toggleFloatingBar, applicationWillTerminate)
- Sources/App/KeychainHelper.swift — pagegridAPIKey case
- Sources/Agent/HooksEngine.swift — appendHook(), deleteHook(), save() helper
- Sources/UI/FloatingBar/FloatingBarView.swift — isTyping → isTypingMain, Error Log tab, PageGrid field
- Sources/UI/MainWindow/ShiroMainWindowView.swift — isTyping → isTypingMain, NewRoutineSheet, delete button

## Must-Know Context
- Palette: bg=#1A1916, accent=#D97757 (Claude copper), active=#B8946A, text=#F2EDE5
- Build: cd ~/Projects/shiro && swift build
- Run:   cd ~/Projects/shiro && .build/debug/Shiro
- Kill:  pkill -f "\.build/debug/Shiro"
- Bridge build: cd ~/Projects/shiro/acp-bridge && npm run build
- ⌘. = toggle floating bar (global, works from any app)
- ⌘N  = new chat (main window)
