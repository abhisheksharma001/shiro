import Foundation
import Combine

/// Central state object. Single source of truth for the whole app.
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    // MARK: - Published State
    @Published var isListening:           Bool    = false
    @Published var isMeetingMode:         Bool    = false
    @Published var isProcessing:          Bool    = false
    @Published var currentTranscript:     String  = ""
    @Published var agentStatus:           AgentStatus = .idle
    @Published var recentTasks:           [ShiroTask] = []
    @Published var pendingTaskApprovals:  [ShiroTask] = []
    @Published var lmStudioConnected:     Bool    = false
    @Published var activeModels:          [String] = []
    @Published var errorMessage:          String? = nil
    @Published var activeRouteMode:       Config.RouteMode = Config.routeMode
    /// Live bridge lifecycle state — drives the status indicator in the floating bar.
    @Published var bridgeStatus:          BridgeStatus = .starting

    // MARK: - Services
    private(set) var database:         ShiroDatabase?
    private(set) var lmStudio:         LMStudioClient?
    private(set) var stt:              STTService?
    private(set) var screenCapture:    ScreenCaptureService?
    private(set) var agentCoordinator: AgentCoordinator?
    private(set) var knowledgeGraph:   KnowledgeGraphService?
    private(set) var acpBridge:        ACPBridge?
    private(set) var bridgeRouter:     (any BridgeRouter)?
    private(set) var claudeCodeRouter: ClaudeCodeRouter?
    private(set) var consentGate:      ConsentGate?
    private(set) var subAgentManager:  SubAgentManager?
    private(set) var embeddingService: EmbeddingService?
    private(set) var memoryStore:      MemoryStore?
    private(set) var ingestor:         Ingestor?
    private(set) var telegramRelay:    TelegramRelay?
    private(set) var mcpRegistry:      MCPRegistry?
    private(set) var skillsRegistry:   SkillsRegistry?
    private(set) var hooksEngine:      HooksEngine?
    private(set) var healthMonitor:    BridgeHealthMonitor?

    private init() {}

    // MARK: - Initialize

    func initialize() async {
        do {
            // 1. Database
            let db = try ShiroDatabase()
            self.database = db

            // 2. LM Studio — only probe if needed; skip in claudeCode to avoid
            //    nw_socket Connection-refused spam when LM Studio is offline.
            let lm = LMStudioClient()
            self.lmStudio = lm
            if Config.routeMode != .claudeCode {
                self.lmStudioConnected = await lm.healthCheck()
                if lmStudioConnected { self.activeModels = await lm.loadedModels() }
            } else {
                print("[Shiro] ℹ️  LM Studio probe skipped (Claude Code CLI route)")
            }

            // 3. Knowledge graph
            guard let kg = KnowledgeGraphService(database: db, lmStudio: lm) as KnowledgeGraphService? else {
                throw AppStateError.dependencyFailed("KnowledgeGraph init failed")
            }
            self.knowledgeGraph = kg

            // 4. STT
            self.stt = STTService(deepgramKey: Config.deepgramAPIKey, lmStudio: lm)

            // 5. Screen capture
            self.screenCapture = ScreenCaptureService(lmStudio: lm, database: db)

            // 6. Agent coordinator
            let coordinator = AgentCoordinator(database: db, lmStudio: lm, knowledgeGraph: kg)
            self.agentCoordinator = coordinator

            // 7. Consent Gate + Sub-agent manager
            let gate = ConsentGate(database: db)
            let sam  = SubAgentManager(database: db)
            self.consentGate    = gate
            self.subAgentManager = sam

            // 7b. Telegram relay (optional)
            if Config.telegramEnabled,
               let token = Config.telegramBotToken,
               let chatId = Config.telegramChatId {
                let relay = TelegramRelay(token: token, chatId: chatId)
                relay.consentGate  = gate
                gate.telegramRelay = relay
                relay.start()
                self.telegramRelay = relay
                print("[Shiro] ✅ Telegram relay started")
            } else {
                print("[Shiro] ℹ️  Telegram relay disabled")
            }

            // 8. Bridge router — with health monitor + full fallback chain
            let monitor = BridgeHealthMonitor(appState: self)
            self.healthMonitor = monitor

            monitor.onStatusChange = { [weak self] status in
                self?.bridgeStatus    = status
                self?.activeRouteMode = Config.routeMode
            }
            monitor.onRouterReady = { [weak self] router in
                guard let self else { return }
                self.rewireRouter(router)
                self.agentCoordinator?.connectBridge(router)
            }

            let mode = Config.routeMode
            self.activeRouteMode = mode
            print("[Shiro] ▸ Route mode: \(mode.displayName)")

            if let router = await buildRouter(for: mode) {
                do {
                    try router.launch()
                    rewireRouter(router)
                    coordinator.connectBridge(router)
                    monitor.attach(to: router, mode: mode)
                    bridgeStatus = .running(routeLabel: router.routeLabel)
                    print("[Shiro] ✅ Router ready: \(router.routeLabel)")
                } catch {
                    print("[Shiro] ⚠️  Primary router failed: \(error.localizedDescription)")
                    bridgeStatus = .restarting(attempt: 1, maxAttempts: 3)
                    // Health monitor will walk the fallback chain.
                    monitor.attach(to: router, mode: mode)
                    // Manually trigger a crash so monitor handles the retry.
                    router.onEvent?(.bridgeError(sessionKey: nil,
                        message: "bridge exited: \(error.localizedDescription)"))
                }
            } else {
                bridgeStatus = .offline(reason: "No usable backend found — check Settings → Route")
                errorMessage = "No LLM backend available. Open Settings → Route to configure."
            }

            // 9. MCP Registry
            self.mcpRegistry = MCPRegistry()

            // 10. Skills Registry
            let skills = SkillsRegistry()
            self.skillsRegistry = skills
            acpBridge?.skillsRegistry = skills

            // 11. Vector RAG — only attempt embeddings when LM Studio is actually up
            let embeddingSvc = EmbeddingService(lmStudio: lm)
            self.embeddingService = embeddingSvc
            let store = MemoryStore(database: db, embeddingService: embeddingSvc)
            self.memoryStore = store
            acpBridge?.memoryStore = store

            let ing = Ingestor(store: store, database: db)
            self.ingestor = ing

            if lmStudioConnected {
                Task.detached(priority: .background) {
                    let dir = (NSHomeDirectory() as NSString).appendingPathComponent("Projects")
                    do {
                        try await ing.ingestDirectory(dir)
                        print("[Shiro] ✅ Ingest of ~/Projects complete")
                    } catch {
                        print("[Shiro] ⚠️  Ingest error: \(error.localizedDescription)")
                    }
                }
            } else {
                print("[Shiro] ℹ️  Ingest skipped (LM Studio offline)")
            }

            // 12. Hooks engine (needs coordinator + skills + ingestor)
            let hooks = HooksEngine(coordinator: coordinator, skillsRegistry: skills, ingestor: ing)
            self.hooksEngine = hooks
            Task { @MainActor in hooks.start() }  // off the init hot-path

            print("[Shiro] ✅ Initialized — route: \(mode.rawValue), LM Studio: \(lmStudioConnected)")

        } catch {
            self.errorMessage = "Init failed: \(error.localizedDescription)"
            self.bridgeStatus = .offline(reason: error.localizedDescription)
            print("[Shiro] ❌ Init error: \(error)")
        }
    }

    // MARK: - Router factory (called by BridgeHealthMonitor + switchRouteMode)

    /// Build (but do NOT launch) a router for `mode`. Returns nil if prerequisites
    /// are missing (e.g. CLI not installed, no API key).
    func buildRouter(for mode: Config.RouteMode) async -> (any BridgeRouter)? {
        switch mode {
        case .claudeCode:
            guard Config.claudeCodeCLIAvailable else {
                print("[Shiro] claudeCode unavailable — CLI not found")
                return nil
            }
            let r = ClaudeCodeRouter()
            self.claudeCodeRouter = r
            return r

        case .anthropic, .lmStudio:
            guard let db = database, let lm = lmStudio,
                  let gate = consentGate, let sam = subAgentManager,
                  let kg = knowledgeGraph, let sc = screenCapture else {
                print("[Shiro] ACPBridge missing dependencies for \(mode.rawValue)")
                return nil
            }
            let bridge = ACPBridge(database: db, knowledgeGraph: kg,
                                   lmStudio: lm, screenCapture: sc)
            bridge.consentGate     = gate
            bridge.subAgentManager = sam
            bridge.skillsRegistry  = skillsRegistry
            bridge.memoryStore     = memoryStore
            self.acpBridge = bridge
            return bridge
        }
    }

    /// Point all service references at the new router and update published state.
    func rewireRouter(_ router: any BridgeRouter) {
        self.bridgeRouter    = router
        self.activeRouteMode = Config.routeMode
        if let bridge = router as? ACPBridge {
            self.acpBridge = bridge
            bridge.skillsRegistry = skillsRegistry
            bridge.memoryStore    = memoryStore
        }
    }

    // MARK: - Route switching (from Settings UI)

    func switchRouteMode(_ newMode: Config.RouteMode) async {
        Config.setRouteMode(newMode)
        healthMonitor?.stop()
        bridgeRouter?.stop()
        acpBridge        = nil
        claudeCodeRouter = nil
        bridgeRouter     = nil
        bridgeStatus     = .starting

        guard let coordinator = agentCoordinator else { return }

        if let router = await buildRouter(for: newMode) {
            do {
                try router.launch()
                rewireRouter(router)
                coordinator.connectBridge(router)
                activeRouteMode = newMode
                bridgeStatus    = .running(routeLabel: router.routeLabel)

                // Re-attach health monitor
                let monitor = BridgeHealthMonitor(appState: self)
                self.healthMonitor = monitor
                monitor.onStatusChange = { [weak self] s in self?.bridgeStatus    = s }
                monitor.onRouterReady  = { [weak self] r in
                    self?.rewireRouter(r)
                    self?.agentCoordinator?.connectBridge(r)
                }
                monitor.attach(to: router, mode: newMode)
                print("[Shiro] ✅ Switched to \(newMode.displayName)")
            } catch {
                errorMessage = "Switch to \(newMode.displayName) failed: \(error.localizedDescription)"
                bridgeStatus = .offline(reason: error.localizedDescription)
            }
        } else {
            errorMessage = "\(newMode.displayName) prerequisites missing"
            bridgeStatus = .offline(reason: "prerequisites missing for \(newMode.rawValue)")
        }
    }
}

// MARK: - Errors

enum AppStateError: LocalizedError {
    case dependencyFailed(String)
    var errorDescription: String? {
        switch self { case .dependencyFailed(let s): return s }
    }
}

// MARK: - Agent Status

enum AgentStatus: Equatable {
    case idle
    case listening
    case thinking
    case acting(tool: String)
    case speaking
    case error(String)

    var label: String {
        switch self {
        case .idle:              return "Idle"
        case .listening:         return "Listening…"
        case .thinking:          return "Thinking…"
        case .acting(let tool):  return "Using \(tool)…"
        case .speaking:          return "Speaking…"
        case .error(let msg):    return "Error: \(msg)"
        }
    }

    var color: String {
        switch self {
        case .idle:      return "gray"
        case .listening: return "blue"
        case .thinking:  return "purple"
        case .acting:    return "orange"
        case .speaking:  return "green"
        case .error:     return "red"
        }
    }
}
