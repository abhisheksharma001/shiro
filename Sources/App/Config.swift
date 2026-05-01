import Foundation

/// All runtime configuration. Reads from environment variables or UserDefaults.
/// Set env vars in Xcode scheme or your shell before launching.
enum Config {

    // MARK: - LM Studio
    static let lmStudioBaseURL: String =
        ProcessInfo.processInfo.environment["LM_STUDIO_URL"] ?? "http://localhost:1234"

    // MARK: - Models
    // Currently loaded in LM Studio (4 models, ~29GB total)
    static let brainModel: String =
        ProcessInfo.processInfo.environment["SHIRO_BRAIN_MODEL"] ?? "google/gemma-4-26b-a4b"
    // Gemma 4 26B — vision + tool calling, 18GB

    static let fastModel: String =
        ProcessInfo.processInfo.environment["SHIRO_FAST_MODEL"] ?? "qwen/qwen3-8b"
    // qwen3-8b — fast router + simple Q&A, 4.6GB

    static let visionModel: String =
        ProcessInfo.processInfo.environment["SHIRO_VISION_MODEL"] ?? "qwen/qwen2.5-vl-7b"
    // Qwen2.5-VL-7B — dedicated screen/image analysis, 6GB

    static let embeddingModel: String =
        ProcessInfo.processInfo.environment["SHIRO_EMBED_MODEL"] ?? "text-embedding-embeddinggemma-300m-qat"
    // Gemma embed 300M QAT — fast local embeddings, 229MB

    // STT: Deepgram (streaming, real-time) — requires DEEPGRAM_API_KEY env var
    // No local whisper loaded currently. Load whisper-large-v3-turbo in LM Studio
    // to enable fully offline STT as fallback.

    // MARK: - Anthropic API (BYOK — use real Claude instead of LM Studio)
    /// Set via Settings UI (stored in Keychain) or ANTHROPIC_API_KEY env var.
    /// When set to a real sk-ant-... key, the Node bridge routes directly to
    /// Anthropic instead of through the LM Studio proxy.
    static var anthropicAPIKey: String? {
        KeychainHelper.get(.anthropicAPIKey)
            ?? ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]
    }
    /// True when a real Anthropic key is configured (not the LM Studio placeholder).
    static var anthropicEnabled: Bool {
        guard let key = anthropicAPIKey else { return false }
        return key.hasPrefix("sk-ant-") || key.hasPrefix("sk-")
    }

    // MARK: - OpenAI-compatible override (any OpenAI-API provider)
    static var openAIAPIKey: String? {
        KeychainHelper.get(.openAIAPIKey)
            ?? ProcessInfo.processInfo.environment["OPENAI_API_KEY"]
    }
    static var openAIBaseURL: String? {
        KeychainHelper.get(.openAIBaseURL)
            ?? ProcessInfo.processInfo.environment["OPENAI_BASE_URL"]
    }

    // MARK: - Deepgram (optional — used for live streaming STT in meetings)
    /// Set via Settings UI (Keychain) or DEEPGRAM_API_KEY env var.
    static var deepgramAPIKey: String? {
        KeychainHelper.get(.deepgramAPIKey)
            ?? ProcessInfo.processInfo.environment["DEEPGRAM_API_KEY"]
    }
    static var deepgramEnabled: Bool {
        guard let k = deepgramAPIKey else { return false }
        return !k.isEmpty
    }

    // MARK: - Database
    static var databasePath: URL {
        let fm = FileManager.default
        let support: URL
        if let u = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            support = u
        } else {
            // Sandbox or unusual environment — fall back to ~/Library/Application Support
            let home = NSHomeDirectory()
            support = URL(fileURLWithPath: home)
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        }
        let dir = support.appendingPathComponent("Shiro", isDirectory: true)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            // Last resort: temp dir. Keeps the app bootable so the error surfaces in a log.
            let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("Shiro", isDirectory: true)
            try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
            return tmp.appendingPathComponent("shiro.db")
        }
        return dir.appendingPathComponent("shiro.db")
    }

    // MARK: - Consent
    /// Seconds to wait for a high-risk tool approval before auto-denying.
    static let approvalTimeoutSeconds: TimeInterval = 300  // 5 min

    // MARK: - Screen Capture
    static let screenCaptureInterval: TimeInterval = 30  // seconds between screen analyses
    static let screenCaptureFPS: Double = 2.0             // frames per second for recording

    // MARK: - Agent
    static let maxAgentIterations: Int = 10
    static let maxSubAgents: Int = 3
    static let agentTimeoutSeconds: TimeInterval = 300   // 5 min hard timeout

    // MARK: - Telegram (consent relay + notifications)
    static var telegramBotToken: String? {
        KeychainHelper.get(.telegramBotToken)
            ?? ProcessInfo.processInfo.environment["TELEGRAM_BOT_TOKEN"]
    }
    static var telegramChatId: String? {
        KeychainHelper.get(.telegramChatId)
            ?? ProcessInfo.processInfo.environment["TELEGRAM_CHAT_ID"]
    }
    static var telegramEnabled: Bool {
        guard let t = telegramBotToken, let c = telegramChatId else { return false }
        return !t.isEmpty && !c.isEmpty
    }

    // MARK: - Meeting Mode
    static let meetingTranscriptFlushInterval: TimeInterval = 120  // summarize every 2 min
    static let stuckScreenThreshold: TimeInterval = 300            // 5 min = stuck

    // MARK: - Route Mode (which LLM backend drives the agent)
    enum RouteMode: String, CaseIterable, Identifiable {
        case lmStudio   = "lmstudio"      // local LM Studio proxy (free, offline)
        case anthropic  = "anthropic"     // BYOK — direct Anthropic API, billed separately
        case claudeCode = "claude-code"   // shell out to `claude` CLI, uses Pro/Max subscription

        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .lmStudio:   return "LM Studio (local, free)"
            case .anthropic:  return "Anthropic API (BYOK)"
            case .claudeCode: return "Claude Code CLI (uses Pro/Max subscription)"
            }
        }
    }

    /// Preferred route mode. Explicit user choice > env var > automatic fallback.
    /// Automatic fallback order: claudeCode (if CLI exists) → anthropic (if key set) → lmStudio.
    static var routeMode: RouteMode {
        if let stored = UserDefaults.standard.string(forKey: "shiro.routeMode"),
           let mode   = RouteMode(rawValue: stored) {
            return mode
        }
        if let env = ProcessInfo.processInfo.environment["SHIRO_ROUTE_MODE"],
           let mode = RouteMode(rawValue: env) {
            return mode
        }
        // Automatic: prefer subscription CLI if present, then BYOK, then local.
        if claudeCodeCLIPath != nil { return .claudeCode }
        if anthropicEnabled         { return .anthropic }
        return .lmStudio
    }

    static func setRouteMode(_ mode: RouteMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: "shiro.routeMode")
    }

    // MARK: - Active model override (for /model Telegram command)

    /// Optional model override set by the Telegram /model command.
    /// nil = use backend default.
    static var activeModel: String? {
        UserDefaults.standard.string(forKey: "shiro.activeModel")
    }

    static func setActiveModel(_ model: String) {
        UserDefaults.standard.set(model, forKey: "shiro.activeModel")
    }

    /// Absolute path to the `claude` CLI binary if installed, else nil.
    /// Searched in order: $SHIRO_CLAUDE_PATH → ~/.local/bin → ~/.claude/local → /opt/homebrew/bin → /usr/local/bin → PATH.
    static var claudeCodeCLIPath: String? {
        if let override = ProcessInfo.processInfo.environment["SHIRO_CLAUDE_PATH"],
           FileManager.default.isExecutableFile(atPath: override) {
            return override
        }
        let home = NSHomeDirectory()
        let candidates = [
            "\(home)/.local/bin/claude",
            "\(home)/.claude/local/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }
    static var claudeCodeCLIAvailable: Bool { claudeCodeCLIPath != nil }

    // MARK: - Agent filesystem access
    /// Directories the agent can read/write through the `claude` CLI (`--add-dir`).
    /// Defaults to $HOME (full PC access) — override with SHIRO_ALLOWED_DIRS env var
    /// (colon-separated) or via UserDefaults "shiro.allowedDirs" (array of strings).
    static var allowedDirectories: [String] {
        if let stored = UserDefaults.standard.array(forKey: "shiro.allowedDirs") as? [String],
           !stored.isEmpty {
            return stored.map { ($0 as NSString).expandingTildeInPath }
        }
        if let env = ProcessInfo.processInfo.environment["SHIRO_ALLOWED_DIRS"], !env.isEmpty {
            return env.split(separator: ":").map {
                (String($0) as NSString).expandingTildeInPath
            }
        }
        return [NSHomeDirectory()]
    }

    static func setAllowedDirectories(_ dirs: [String]) {
        UserDefaults.standard.set(dirs, forKey: "shiro.allowedDirs")
    }

    /// Default permission mode for the Claude CLI. `bypassPermissions` lets the
    /// agent act without per-tool prompts (we still route through ConsentGate for
    /// high-risk Swift-side tools). Override with SHIRO_CLAUDE_PERMISSION.
    static var claudePermissionMode: String {
        ProcessInfo.processInfo.environment["SHIRO_CLAUDE_PERMISSION"] ?? "bypassPermissions"
    }
}
