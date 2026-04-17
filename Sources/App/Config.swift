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

    // MARK: - Deepgram (optional — used for live streaming STT in meetings)
    /// Set DEEPGRAM_API_KEY in your environment to enable Deepgram streaming.
    /// If not set, falls back to LM Studio whisper for batch transcription.
    static let deepgramAPIKey: String? =
        ProcessInfo.processInfo.environment["DEEPGRAM_API_KEY"]

    static var deepgramEnabled: Bool { deepgramAPIKey != nil && deepgramAPIKey?.isEmpty == false }

    // MARK: - Database
    static var databasePath: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("Shiro", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("shiro.db")
    }

    // MARK: - Screen Capture
    static let screenCaptureInterval: TimeInterval = 30  // seconds between screen analyses
    static let screenCaptureFPS: Double = 2.0             // frames per second for recording

    // MARK: - Agent
    static let maxAgentIterations: Int = 10
    static let maxSubAgents: Int = 3
    static let agentTimeoutSeconds: TimeInterval = 300   // 5 min hard timeout

    // MARK: - Meeting Mode
    static let meetingTranscriptFlushInterval: TimeInterval = 120  // summarize every 2 min
    static let stuckScreenThreshold: TimeInterval = 300            // 5 min = stuck
}
