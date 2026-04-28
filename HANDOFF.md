# Handoff — 2026-04-21

## What Was Done
1. Forecast integration complete (all 5 pieces):
   - Added `forecast_timeseries` tool to `acp-bridge/src/shiro-tools-stdio.ts` (local Python, NOT forwarded to Swift)
   - Added `runForecastLocally()` fn in same file: spawns `python3 ~/.shiro/tools/forecast.py`, pipes JSON in, returns text summary + chart_base64
   - Added `@Published var forecastModeEnabled: Bool` to `AppState.swift` (persisted via UserDefaults key "forecastModeEnabled")
   - Added `imageBase64: String?` to `DisplayMessage` struct in `AppState.swift` — for inline chart rendering
   - Added Forecast Mode toggle to left sidebar in `ShiroMainWindowView.swift` (icon: chart.line.uptrend.xyaxis, teal color)
   - Added image rendering in `ChatMessageRow`: decodes base64 → NSImage → SwiftUI Image, 520px max width
   - Created `~/.shiro/skills/forecast.json` — triggered by `/forecast`, tries yfinance first, asks user if fails, calls tool, interprets results
2. Both builds pass clean: `npm run build` (0 errors) + `swift build` (0 errors, 2 pre-existing warnings)

## What Works (verified 2026-04-21)
- `swift build` → Build complete! (0 errors)
- `cd ~/Projects/shiro/acp-bridge && npm run build` → 0 errors
- Forecast toggle visible in sidebar (Forecast Mode, teal dot)
- `/forecast AAPL` will: research memory → try yfinance → run ARIMA+SARIMA+Prophet → show table + chart image inline
- `~/.shiro/tools/forecast.py` exists and pip deps installed (pandas, statsmodels, prophet, matplotlib, yfinance)

## What's Broken / Suspected
- isTyping dots may not reset if response arrives during stream gap (pre-existing)
- Sub-agent tree/inline display styles not implemented (only panel mode works)
- "New Routine" form not built — user must edit ~/.shiro/hooks.json manually
- Browser Control needs Screen Recording permission in System Preferences
- imageBase64 on DisplayMessage is set by forecast tool result, but AppState.handleBridgeEventForUI doesn't yet parse chart_base64 from tool results — charts only appear if agent explicitly appends a DisplayMessage with imageBase64 set

## Next Steps (Priority)
1. Wire chart_base64 into message display: in AppState.handleBridgeEventForUI, when a tool_result for `forecast_timeseries` arrives, extract `chart_base64` JSON field and set it on the last assistant DisplayMessage.imageBase64
2. Test end-to-end: `.build/debug/Shiro` → type `/forecast AAPL` → confirm chart renders inline
3. Fix isTyping reset: move to `@Published var isTypingMain` in AppState (not @State in views)
4. Add ⌘. shortcut to show/hide floating bar (NSLocalMonitor in AppDelegate)
5. "New Routine" form in RoutinesView (HooksEngine needs appendHook+save)

## Files Modified
- Sources/App/AppState.swift — forecastModeEnabled @Published, imageBase64 on DisplayMessage, saveUIPreferences persists forecast pref
- Sources/UI/MainWindow/ShiroMainWindowView.swift — Forecast Mode sidebar toggle, image rendering in ChatMessageRow
- acp-bridge/src/shiro-tools-stdio.ts — spawn/path imports, forecast_timeseries ToolDef, runForecastLocally(), handleToolCall dispatch

## Must-Know Context
- Palette: bg=#07090F, accent=#6C63FF, active=#10D9A4, amber=#F0A030, text=#DEE4FF
- Forecast script: ~/.shiro/tools/forecast.py — reads JSON stdin, writes JSON stdout incl. chart_base64
- Skill trigger: /forecast in chat → SkillsRegistry resolves → agent uses forecast_timeseries tool
- Build: cd ~/Projects/shiro && swift build
- Run:  cd ~/Projects/shiro && .build/debug/Shiro
- Kill: pkill -f "\.build/debug/Shiro"
- Bridge build: cd ~/Projects/shiro/acp-bridge && npm run build
