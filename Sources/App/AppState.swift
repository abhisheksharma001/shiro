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
            self.agentCoordinator = AgentCoordinator(
                database: db,
                lmStudio: lm,
                knowledgeGraph: knowledgeGraph!
            )

            print("[Shiro] ✅ Initialized — LM Studio: \(lmStudioConnected), Models: \(activeModels.count)")
        } catch {
            self.errorMessage = "Init failed: \(error.localizedDescription)"
            print("[Shiro] ❌ Init error: \(error)")
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
