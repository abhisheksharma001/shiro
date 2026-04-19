import Foundation
import Combine

/// Central state object. Single source of truth for the whole app.
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    // MARK: - Published State
    @Published var isListening: Bool = false
    @Published var isMeetingMode: Bool = false
    @Published var isProcessing: Bool = false
    @Published var currentTranscript: String = ""
    @Published var agentStatus: AgentStatus = .idle
    @Published var recentTasks: [ShiroTask] = []
    @Published var pendingTaskApprovals: [ShiroTask] = []
    @Published var lmStudioConnected: Bool = false
    @Published var activeModels: [String] = []
    @Published var errorMessage: String? = nil

    // MARK: - Services (initialized once)
    private(set) var database: ShiroDatabase?
    private(set) var lmStudio: LMStudioClient?
    private(set) var stt: STTService?
    private(set) var screenCapture: ScreenCaptureService?
    private(set) var agentCoordinator: AgentCoordinator?
    private(set) var knowledgeGraph: KnowledgeGraphService?
    private(set) var acpBridge: ACPBridge?
    /// Active router in use (one of acpBridge / claudeCodeRouter).
    private(set) var bridgeRouter: (any BridgeRouter)?
    private(set) var claudeCodeRouter: ClaudeCodeRouter?
    /// Currently-active route mode (for UI display).
    @Published var activeRouteMode: Config.RouteMode = .lmStudio
    private(set) var consentGate: ConsentGate?
    private(set) var subAgentManager: SubAgentManager?
    private(set) var embeddingService: EmbeddingService?
    private(set) var memoryStore: MemoryStore?
    private(set) var ingestor: Ingestor?
    private(set) var telegramRelay: TelegramRelay?
    private(set) var mcpRegistry: MCPRegistry?
    private(set) var skillsRegistry: SkillsRegistry?
    private(set) var hooksEngine: HooksEngine?

    private init() {}

    func initialize() async {
        do {
            // 1. Database
            let db = try ShiroDatabase()
            self.database = db

            // 2. LM Studio client
            let lm = LMStudioClient()
            self.lmStudio = lm
            self.lmStudioConnected = await lm.healthCheck()
            if lmStudioConnected {
                self.activeModels = await lm.loadedModels()
            }

            // 3. Knowledge graph
            self.knowledgeGraph = KnowledgeGraphService(database: db, lmStudio: lm)

            // 4. STT
            let deepgramKey = Config.deepgramAPIKey
            self.stt = STTService(
                deepgramKey: deepgramKey,
                lmStudio: lm
            )

            // 5. Screen capture
            self.screenCapture = ScreenCaptureService(lmStudio: lm, database: db)

            // 6. Agent coordinator
            let coordinator = AgentCoordinator(
                database: db,
                lmStudio: lm,
                knowledgeGraph: knowledgeGraph!
            )
            self.agentCoordinator = coordinator

            // 7. Consent Gate + Sub-agent manager
            let gate = ConsentGate(database: db)
            self.consentGate    = gate
            let sam = SubAgentManager(database: db)
            self.subAgentManager = sam

            // 7b. Telegram relay (optional — only if env vars are set)
            if Config.telegramEnabled,
               let botToken = Config.telegramBotToken,
               let chatId   = Config.telegramChatId {
                let relay = TelegramRelay(token: botToken, chatId: chatId)
                relay.consentGate = gate
                gate.telegramRelay = relay
                relay.start()
                self.telegramRelay = relay
                print("[Shiro] ✅ Telegram relay started")
            } else {
                print("[Shiro] ℹ️  Telegram relay disabled (set TELEGRAM_BOT_TOKEN + TELEGRAM_CHAT_ID to enable)")
            }

            // 8. Router — pick backend based on Config.routeMode
            //
            //   .claudeCode → spawn local `claude` CLI (uses Pro/Max subscription)
            //   .anthropic  → Node acp-bridge with real API key (BYOK)
            //   .lmStudio   → Node acp-bridge proxying LM Studio (fully local)
            let mode = Config.routeMode
            self.activeRouteMode = mode
            print("[Shiro] ▸ Route mode: \(mode.displayName)")

            switch mode {
            case .claudeCode:
                let router = ClaudeCodeRouter()
                self.claudeCodeRouter = router
                do {
                    try router.launch()
                    self.bridgeRouter = router
                    coordinator.connectBridge(router)
                    print("[Shiro] ✅ Claude Code CLI router launched (subscription mode)")
                } catch {
                    self.errorMessage = "Claude CLI failed to start: \(error.localizedDescription). Falling back to local."
                    print("[Shiro] ⚠️  Claude CLI unavailable — falling back to ACP bridge: \(error)")
                    // Automatic fallback → ACP bridge.
                    _ = launchACPBridge(db: db, lm: lm, gate: gate, sam: sam, coordinator: coordinator)
                }

            case .anthropic, .lmStudio:
                _ = launchACPBridge(db: db, lm: lm, gate: gate, sam: sam, coordinator: coordinator)
            }

            // 9. MCP Registry (Phase 4) — reads ~/.shiro/mcp.json, creates defaults if missing
            let registry = MCPRegistry()
            self.mcpRegistry = registry

            // 10. Skills Registry (Phase 5) — reads ~/.shiro/skills/*.json
            let skills = SkillsRegistry()
            self.skillsRegistry = skills
            self.acpBridge?.skillsRegistry = skills

            // 10b. Hooks Engine (Phase 6) — fires on file changes, schedule, launch
            // Requires coordinator + skills + ingestor — init after all three are ready.

            // 11. Vector RAG (Phase 3)
            let embeddingSvc = EmbeddingService(lmStudio: lm)
            self.embeddingService = embeddingSvc

            let store = MemoryStore(database: db, embeddingService: embeddingSvc)
            self.memoryStore = store
            self.acpBridge?.memoryStore = store

            let ing = Ingestor(store: store, database: db)
            self.ingestor = ing

            // Background auto-ingest: index ~/Projects on first launch, then periodically.
            Task.detached(priority: .background) {
                let projectsDir = (NSHomeDirectory() as NSString).appendingPathComponent("Projects")
                do {
                    try await ing.ingestDirectory(projectsDir)
                    print("[Shiro] ✅ Initial ingest of ~/Projects complete")
                } catch {
                    print("[Shiro] ⚠️  Ingest error: \(error.localizedDescription)")
                }
            }

            // Start hooks engine — all dependencies now available
            let hooks = HooksEngine(coordinator: coordinator, skillsRegistry: skills, ingestor: ing)
            self.hooksEngine = hooks
            hooks.start()

            print("[Shiro] ✅ Initialized — LM Studio: \(lmStudioConnected), Models: \(activeModels.count)")
        } catch {
            self.errorMessage = "Init failed: \(error.localizedDescription)"
            print("[Shiro] ❌ Init error: \(error)")
        }
    }

    /// Instantiate and launch the Node ACPBridge (LM Studio / Anthropic modes).
    /// Assigns `self.acpBridge` + `self.bridgeRouter` on success.
    @discardableResult
    private func launchACPBridge(
        db: ShiroDatabase,
        lm: LMStudioClient,
        gate: ConsentGate,
        sam: SubAgentManager,
        coordinator: AgentCoordinator
    ) -> Bool {
        guard let kg = knowledgeGraph, let sc = screenCapture else {
            errorMessage = "Bridge launch missing dependencies"
            return false
        }
        let bridge = ACPBridge(
            database:       db,
            knowledgeGraph: kg,
            lmStudio:       lm,
            screenCapture:  sc
        )
        bridge.consentGate     = gate
        bridge.subAgentManager = sam
        self.acpBridge = bridge

        do {
            try bridge.launch()
            self.bridgeRouter = bridge
            coordinator.connectBridge(bridge)
            print("[Shiro] ✅ ACP bridge launched (PID \(bridge.bridgePID))")
            return true
        } catch {
            self.errorMessage = "ACP bridge failed: \(error.localizedDescription)"
            print("[Shiro] ⚠️  ACP bridge unavailable: \(error)")
            return false
        }
    }

    /// Called by Settings UI when the user picks a different route mode.
    /// Tears down the current router, applies the new mode, and re-launches.
    func switchRouteMode(_ newMode: Config.RouteMode) async {
        Config.setRouteMode(newMode)
        // Stop current
        bridgeRouter?.stop()
        acpBridge        = nil
        claudeCodeRouter = nil
        bridgeRouter     = nil
        // Re-launch the appropriate backend.
        guard let db = database, let lm = lmStudio,
              let gate = consentGate, let sam = subAgentManager,
              let coord = agentCoordinator else { return }
        activeRouteMode = newMode
        switch newMode {
        case .claudeCode:
            let router = ClaudeCodeRouter()
            self.claudeCodeRouter = router
            do {
                try router.launch()
                self.bridgeRouter = router
                coord.connectBridge(router)
                print("[Shiro] ✅ Switched to Claude Code CLI")
            } catch {
                errorMessage = "Claude CLI failed: \(error.localizedDescription)"
                launchACPBridge(db: db, lm: lm, gate: gate, sam: sam, coordinator: coord)
            }
        case .anthropic, .lmStudio:
            launchACPBridge(db: db, lm: lm, gate: gate, sam: sam, coordinator: coord)
            // Rewire skills + memory on the new acpBridge.
            acpBridge?.skillsRegistry = skillsRegistry
            acpBridge?.memoryStore    = memoryStore
        }
    }
}

enum AgentStatus: Equatable {
    case idle
    case listening
    case thinking
    case acting(tool: String)
    case speaking
    case error(String)

    var label: String {
        switch self {
        case .idle: return "Idle"
        case .listening: return "Listening…"
        case .thinking: return "Thinking…"
        case .acting(let tool): return "Using \(tool)…"
        case .speaking: return "Speaking…"
        case .error(let msg): return "Error: \(msg)"
        }
    }

    var color: String {
        switch self {
        case .idle: return "gray"
        case .listening: return "blue"
        case .thinking: return "purple"
        case .acting: return "orange"
        case .speaking: return "green"
        case .error: return "red"
        }
    }
}
