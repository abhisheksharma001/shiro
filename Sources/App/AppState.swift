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

    // MARK: - Conversation (shared between floating bar and main window)
    @Published var conversationMessages:  [DisplayMessage] = []

    /// Floating-bar expansion state — single source of truth. The window controller
    /// observes this via Combine and animates the NSPanel frame manually. Doing
    /// it this way (instead of NSHostingController.sizingOptions) avoids the
    /// NSISEngine feedback loop / stack-overflow crash we hit at 18:50 / 19:19.
    @Published var isFloatingExpanded:    Bool    = false

    // MARK: - Browser Control
    @Published var browserControlEnabled: Bool    = false
    @Published var latestScreenSummary:   String? = nil

    // MARK: - Sub-agent display (polled from SubAgentManager actor)
    @Published var subAgentSessions:       [SubAgentDisplayInfo] = []
    @Published var subAgentCompletedCount: Int = 0
    @Published var subAgentFailedCount:    Int = 0

    // MARK: - UI Layout Preferences (persisted via UserDefaults)
    @Published var uiShowAgentsPanel:  Bool = UserDefaults.standard.object(forKey: "uiShowAgentsPanel")  as? Bool ?? true
    @Published var uiShowToolFeed:     Bool = UserDefaults.standard.object(forKey: "uiShowToolFeed")     as? Bool ?? true
    @Published var uiSubAgentStyle:    SubAgentDisplayStyle = SubAgentDisplayStyle(rawValue: UserDefaults.standard.string(forKey: "uiSubAgentStyle") ?? "") ?? .panel

    // MARK: - Forecast Mode
    @Published var forecastModeEnabled: Bool = UserDefaults.standard.object(forKey: "forecastModeEnabled") as? Bool ?? false

    // MARK: - Tool Activity Feed (live append from bridge events)
    @Published var toolActivityFeed:   [ToolActivityItem] = []

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

    // MARK: - Browser Control

    func setBrowserControl(_ enabled: Bool) {
        browserControlEnabled = enabled
        if enabled {
            screenCapture?.onAnalysis = { [weak self] analysis in
                Task { @MainActor [weak self] in
                    self?.latestScreenSummary = "[\(analysis.app)] \(analysis.windowTitle) — \(analysis.activity)"
                }
            }
            screenCapture?.startCapturing()
        } else {
            screenCapture?.stopCapturing()
            screenCapture?.onAnalysis = nil
            latestScreenSummary = nil
        }
    }

    // MARK: - Sub-agent Display Refresh (called periodically from UI)

    func refreshSubAgentSessions() async {
        guard let sam = subAgentManager else { return }
        let sessions = await sam.activeSessions
        let completed = await sam.completedCount
        let failed = await sam.failedCount
        subAgentSessions = sessions.values.map { s in
            SubAgentDisplayInfo(
                id: s.sessionKey,
                taskId: s.taskId,
                parentKey: s.parentKey,
                depth: s.depth,
                costAccrued: s.costAccrued,
                costBudget: s.costBudgetUsd ?? SubAgentManager.defaultCostBudgetUsd
            )
        }.sorted { $0.depth < $1.depth }
        subAgentCompletedCount = completed
        subAgentFailedCount    = failed
    }

    // MARK: - Bridge event → UI hook

    /// Called by AppDelegate after every BridgeEvent to keep toolActivityFeed
    /// and inline toolCalls on the streaming assistant message current.
    func handleBridgeEventForUI(_ event: BridgeEvent) {
        switch event {
        case .toolStarted(let sk, let callId, let name, let input):
            // Append to global feed
            let item = ToolActivityItem(
                callId:     callId,
                toolName:   name,
                sessionKey: sk,
                input:      input,
                output:     nil,
                isError:    false,
                isRunning:  true,
                startedAt:  Date()
            )
            appendToolActivity(item)
            // Attach inline to last assistant message
            if conversationMessages.last?.role == .assistant {
                let idx = conversationMessages.indices.last!
                conversationMessages[idx].toolCalls.append(ToolCallInfo(
                    id: callId, name: name,
                    input: (try? String(data: JSONSerialization.data(withJSONObject: input), encoding: .utf8)) ?? "",
                    output: nil, isError: false, isRunning: true
                ))
            }
            agentStatus = .acting(tool: name)

        case .toolFinished(let sk, let callId, let output, let isErr):
            // Update global feed
            if let idx = toolActivityFeed.firstIndex(where: { $0.callId == callId }) {
                let prev = toolActivityFeed[idx]
                toolActivityFeed[idx] = ToolActivityItem(
                    callId:     prev.callId,
                    toolName:   prev.toolName,
                    sessionKey: sk,
                    input:      prev.input,
                    output:     String(output.prefix(120)),
                    isError:    isErr,
                    isRunning:  false,
                    startedAt:  prev.startedAt
                )
            }
            // Update inline chip on last assistant message
            for i in conversationMessages.indices.reversed() {
                if let j = conversationMessages[i].toolCalls.firstIndex(where: { $0.id == callId }) {
                    conversationMessages[i].toolCalls[j].output    = String(output.prefix(80))
                    conversationMessages[i].toolCalls[j].isError   = isErr
                    conversationMessages[i].toolCalls[j].isRunning = false
                    // Extract chart image when forecast_timeseries completes successfully
                    if !isErr && conversationMessages[i].toolCalls[j].name == "forecast_timeseries",
                       let data = output.data(using: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let chartBase64 = json["chart_base64"] as? String {
                        conversationMessages[i].imageBase64 = chartBase64
                    }
                    break
                }
            }

        default:
            break
        }
    }

    // MARK: - Tool Activity

    func appendToolActivity(_ item: ToolActivityItem) {
        toolActivityFeed.append(item)
        // Cap feed at 200 items
        if toolActivityFeed.count > 200 {
            toolActivityFeed.removeFirst(toolActivityFeed.count - 200)
        }
    }

    // MARK: - Conversation

    /// Wipe the chat thread, tool feed, and any in-flight turn.
    /// Safe to call mid-stream — the agent is interrupted first so leftover
    /// streaming tokens don't repopulate the cleared conversation.
    func clearConversation() {
        if isProcessing {
            agentCoordinator?.bridge?.interrupt(sessionKey: "main")
            acpBridge?.interrupt(sessionKey: "main")
            // Drop streaming callbacks so any pending tokens are discarded.
            agentCoordinator?.onStreamingToken = nil
            agentCoordinator?.onTurnComplete   = nil
        }
        isProcessing          = false
        agentStatus           = .idle
        conversationMessages.removeAll()
        toolActivityFeed.removeAll()
        // Collapse the floating bar back to compact when emptied.
        isFloatingExpanded = false
    }

    // MARK: - Mic / Listening (shared toggle for floating bar + sidebar)

    /// Single entry point for mic toggle. Both the floating-bar mic button
    /// and the sidebar Mic toggle in the workspace window call this.
    func toggleListening() {
        if isListening {
            isListening = false
            agentStatus = .idle
            _ = stt?.stopMeetingMode()
        } else {
            isListening = true
            agentStatus = .listening
            stt?.onSegment = { [weak self] seg in
                guard seg.isFinal else { return }
                Task { @MainActor [weak self] in
                    self?.currentTranscript = seg.text
                }
            }
            stt?.startMeetingMode()
        }
    }

    // MARK: - UI Preferences Persistence

    func saveUIPreferences() {
        UserDefaults.standard.set(uiShowAgentsPanel, forKey: "uiShowAgentsPanel")
        UserDefaults.standard.set(uiShowToolFeed, forKey: "uiShowToolFeed")
        UserDefaults.standard.set(uiSubAgentStyle.rawValue, forKey: "uiSubAgentStyle")
        UserDefaults.standard.set(forecastModeEnabled, forKey: "forecastModeEnabled")
    }
}

// MARK: - Supporting Types (shared across UI)

struct DisplayMessage: Identifiable, Equatable {
    let id: UUID
    let role: MessageRole
    var content: String
    let timestamp: Date
    var badge: String?
    var toolCalls: [ToolCallInfo]
    /// Base64-encoded PNG — set by forecast_timeseries tool result rendering.
    var imageBase64: String?

    init(role: MessageRole, content: String, badge: String? = nil, imageBase64: String? = nil) {
        self.id          = UUID()
        self.role        = role
        self.content     = content
        self.timestamp   = Date()
        self.badge       = badge
        self.toolCalls   = []
        self.imageBase64 = imageBase64
    }

    enum MessageRole { case user, assistant, system }
}

struct ToolCallInfo: Identifiable, Equatable {
    let id: String   // call ID from bridge
    let name: String
    let input: String    // JSON summary
    var output: String?
    var isError: Bool
    var isRunning: Bool
}

struct ToolActivityItem: Identifiable {
    let id = UUID()
    let callId: String
    let toolName: String
    let sessionKey: String
    let input: [String: Any]
    var output: String?
    var isError: Bool
    var isRunning: Bool
    let startedAt: Date

    static func == (lhs: ToolActivityItem, rhs: ToolActivityItem) -> Bool {
        lhs.id == rhs.id
    }
}

struct SubAgentDisplayInfo: Identifiable {
    let id: String        // sessionKey
    let taskId: String?
    let parentKey: String?
    let depth: Int
    let costAccrued: Double
    let costBudget: Double
}

enum SubAgentDisplayStyle: String, CaseIterable {
    case inline  = "inline"
    case panel   = "panel"
    case tree    = "tree"

    var label: String {
        switch self {
        case .inline: return "Inline in Chat"
        case .panel:  return "Side Panel"
        case .tree:   return "Tree View"
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
