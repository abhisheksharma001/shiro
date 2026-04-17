import Foundation
import ScreenCaptureKit
import CoreGraphics
import AppKit
import ImageIO

// MARK: - Screen Analysis Result

struct ScreenAnalysis: Codable {
    let timestamp: Date
    let app: String
    let windowTitle: String
    let activity: String       // editing_code | browsing | reading | writing | meeting | idle
    let contentSummary: String
    let isStuck: Bool          // same screen for > Config.stuckScreenThreshold
    let errorsVisible: Bool
    let actionSuggestion: String?
}

// MARK: - ScreenCaptureService

/// Captures screen at intervals, sends to Qwen2.5-VL-7B for analysis.
/// Updates knowledge graph with activity observations.
@MainActor
final class ScreenCaptureService: NSObject {

    private let lmStudio: LMStudioClient
    private let database: ShiroDatabase

    private var captureTimer: Timer?
    private var lastScreenHash: Int = 0
    private var stuckSince: Date? = nil
    private var lastAnalysis: ScreenAnalysis?

    var onAnalysis: ((ScreenAnalysis) -> Void)?
    var onStuckDetected: ((ScreenAnalysis) -> Void)?

    init(lmStudio: LMStudioClient, database: ShiroDatabase) {
        self.lmStudio = lmStudio
        self.database = database
        super.init()
    }

    // MARK: - Start / Stop

    func startCapturing() {
        guard captureTimer == nil else { return }
        captureTimer = Timer.scheduledTimer(withTimeInterval: Config.screenCaptureInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.captureAndAnalyze()
            }
        }
        print("[Screen] 📸 Started — interval: \(Config.screenCaptureInterval)s")
    }

    func stopCapturing() {
        captureTimer?.invalidate()
        captureTimer = nil
        print("[Screen] 🛑 Stopped")
    }

    // MARK: - Capture + Analyze

    func captureAndAnalyze() async {
        guard let screenshot = await captureScreen() else {
            print("[Screen] ⚠️ Capture failed")
            return
        }

        // Hash to detect if screen changed
        let hash = screenshot.hashValue
        let unchanged = hash == lastScreenHash
        lastScreenHash = hash

        if unchanged {
            if stuckSince == nil { stuckSince = Date() }
        } else {
            stuckSince = nil
        }

        let isStuck: Bool
        if let since = stuckSince {
            isStuck = Date().timeIntervalSince(since) > Config.stuckScreenThreshold
        } else {
            isStuck = false
        }

        // Get active app info from NSWorkspace (faster than asking LLM)
        let activeApp = NSWorkspace.shared.frontmostApplication?.localizedName ?? "Unknown"
        let windowTitle = getFocusedWindowTitle()

        // Only call vision model if screen changed OR we haven't analyzed in 2 min
        let shouldAnalyze = !unchanged || lastAnalysis == nil || {
            guard let last = lastAnalysis else { return true }
            return Date().timeIntervalSince(last.timestamp) > 120
        }()

        guard shouldAnalyze else { return }

        guard let pngData = screenshot.toPNG() else { return }

        // Build vision prompt
        let prompt = """
        Analyze this screenshot. Return JSON only, no explanation.
        {
          "app": "app name",
          "window_title": "window title or best guess",
          "activity": "one of: editing_code|browsing|reading|writing|meeting|terminal|idle|other",
          "content_summary": "1-2 sentence summary of what the user is doing",
          "errors_visible": true/false,
          "action_suggestion": "optional: a helpful suggestion if user seems stuck or has an error, or null"
        }
        Active app from system: \(activeApp)
        Window title hint: \(windowTitle)
        Is screen unchanged for a while: \(isStuck)
        """

        do {
            let raw = try await lmStudio.vision(prompt: prompt, imageData: pngData, maxTokens: 512)
            let analysis = parseAnalysis(raw: raw, app: activeApp, windowTitle: windowTitle, isStuck: isStuck)
            lastAnalysis = analysis

            // Save observation to DB
            let obs = Observation.new(type: "screen", data: [
                "app": analysis.app,
                "window_title": analysis.windowTitle,
                "activity": analysis.activity,
                "content_summary": analysis.contentSummary,
                "errors_visible": analysis.errorsVisible,
                "is_stuck": analysis.isStuck
            ])
            try? await database.pool.write { db in try obs.insert(db) }

            onAnalysis?(analysis)
            if isStuck, let suggestion = analysis.actionSuggestion {
                print("[Screen] 💡 Stuck detected: \(suggestion)")
                onStuckDetected?(analysis)
            }
        } catch {
            print("[Screen] ❌ Vision error: \(error)")
        }
    }

    // MARK: - Manual Snapshot (for user-triggered analysis)

    func analyzeNow() async -> ScreenAnalysis? {
        await captureAndAnalyze()
        return lastAnalysis
    }

    // MARK: - ScreenCaptureKit

    /// Capture one frame and return it as JPEG data.
    /// Used by ACPBridge to fulfill `capture_screenshot` tool calls.
    func captureFrame() async throws -> Data {
        guard let image = await captureScreen() else {
            throw ScreenCaptureError.captureFailedNoImage
        }
        let nsImage = NSImage(cgImage: image, size: .zero)
        guard let tiffData = nsImage.tiffRepresentation,
              let bitmap   = NSBitmapImageRep(data: tiffData),
              let jpeg     = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else {
            throw ScreenCaptureError.encodingFailed
        }
        return jpeg
    }

    private func captureScreen() async -> CGImage? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first else { return nil }

            let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
            let config = SCStreamConfiguration()
            config.width = Int(display.width / 2)   // half resolution is enough for vision
            config.height = Int(display.height / 2)
            config.pixelFormat = kCVPixelFormatType_32BGRA

            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch {
            // Fallback: CGWindowListCreateImage
            return CGWindowListCreateImage(.null, .optionOnScreenOnly, kCGNullWindowID, .bestResolution)
        }
    }

    private func getFocusedWindowTitle() -> String {
        guard let app = NSWorkspace.shared.frontmostApplication else { return "Unknown" }
        let pid = app.processIdentifier
        let axApp = AXUIElementCreateApplication(pid)
        var windowRef: CFTypeRef?
        AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &windowRef)
        guard let window = windowRef else { return "Unknown" }
        var titleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &titleRef)
        return (titleRef as? String) ?? "Unknown"
    }

    // MARK: - Parse Vision Response

    private func parseAnalysis(raw: String, app: String, windowTitle: String, isStuck: Bool) -> ScreenAnalysis {
        // Extract JSON from response (model might wrap it in markdown)
        let jsonString: String
        if let start = raw.range(of: "{"), let end = raw.range(of: "}", options: .backwards) {
            jsonString = String(raw[start.lowerBound...end.upperBound])
        } else {
            jsonString = raw
        }

        struct VisionJSON: Decodable {
            let app: String?
            let window_title: String?
            let activity: String?
            let content_summary: String?
            let errors_visible: Bool?
            let action_suggestion: String?
        }

        if let data = jsonString.data(using: .utf8),
           let parsed = try? JSONDecoder().decode(VisionJSON.self, from: data) {
            return ScreenAnalysis(
                timestamp: Date(),
                app: parsed.app ?? app,
                windowTitle: parsed.window_title ?? windowTitle,
                activity: parsed.activity ?? "unknown",
                contentSummary: parsed.content_summary ?? "",
                isStuck: isStuck,
                errorsVisible: parsed.errors_visible ?? false,
                actionSuggestion: isStuck ? parsed.action_suggestion : nil
            )
        }

        // Fallback if JSON parsing fails
        return ScreenAnalysis(
            timestamp: Date(),
            app: app,
            windowTitle: windowTitle,
            activity: "unknown",
            contentSummary: raw.prefix(200).description,
            isStuck: isStuck,
            errorsVisible: false,
            actionSuggestion: nil
        )
    }
}

// MARK: - ScreenCaptureError

enum ScreenCaptureError: LocalizedError {
    case captureFailedNoImage
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .captureFailedNoImage: return "Screen capture returned no image"
        case .encodingFailed:       return "Failed to encode screenshot as JPEG"
        }
    }
}

// MARK: - CGImage Extension

private extension CGImage {
    func toPNG() -> Data? {
        let nsImage = NSImage(cgImage: self, size: .zero)
        guard let tiffData = nsImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else { return nil }
        return bitmap.representation(using: .png, properties: [.compressionFactor: 0.8])
    }

    var hashValue: Int {
        // Quick perceptual hash using image dimensions + a few pixel samples
        var hasher = Hasher()
        hasher.combine(width)
        hasher.combine(height)
        // Sample center pixel as a quick change detector
        if let ctx = CGContext(data: nil, width: 1, height: 1,
                               bitsPerComponent: 8, bytesPerRow: 4,
                               space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            ctx.draw(self, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            if let data = ctx.data {
                hasher.combine(data.load(as: UInt32.self))
            }
        }
        return hasher.finalize()
    }
}
