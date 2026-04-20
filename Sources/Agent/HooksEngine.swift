import Foundation
import AppKit

// MARK: - HooksEngine
//
// Reads ~/.shiro/hooks.json and fires actions when conditions are met.
//
// Hook types:
//   app_launch  — fires once at startup
//   file_watch  — fires when a file/directory is written
//   schedule    — fires at a daily wall-clock time ("09:00") or on an
//                 interval in minutes ("every:30")
//
// Actions:
//   skill  — invoke a skill by name with args
//   query  — send raw text to the agent
//   ingest — ingest a path into memory
//
// All actions are dispatched through the shared AgentCoordinator so they
// participate in the normal consent gate + streaming pipeline.

@MainActor
final class HooksEngine: ObservableObject {

    // MARK: - Model

    struct HookAction: Codable {
        var type: String               // "skill" | "query" | "ingest"
        var skill: String?             // required when type == "skill"
        var args: [String: String]?    // skill parameters
        var query: String?             // required when type == "query"
        var path: String?              // required when type == "ingest"
        var corpus: String?            // optional corpus for ingest
    }

    struct Hook: Codable, Identifiable {
        var id: String { name }
        var name: String
        var type: String               // "app_launch" | "file_watch" | "schedule"
        var path: String?              // for file_watch: path to watch (~ expanded)
        var schedule: String?          // "09:00" (daily) or "every:30" (interval minutes)
        var action: HookAction
        var enabled: Bool
        var description: String?
    }

    struct HooksFile: Codable {
        var hooks: [Hook]
    }

    // MARK: - State

    @Published private(set) var hooks: [Hook] = []

    private var fileWatchSources: [String: DispatchSourceFileSystemObject] = [:]
    /// Interval-based hooks (repeat=true) keep a Timer.
    private var scheduleTimers:   [String: Timer] = [:]
    /// Daily wall-clock hooks use DispatchSourceTimer so they survive sleep.
    private var dailyTimers:      [String: DispatchSourceTimer] = [:]
    /// Remembered so we can re-arm on wake / app-foreground.
    private var dailySchedules:   [String: String] = [:]

    private weak var coordinator: AgentCoordinator?
    private weak var skillsRegistry: SkillsRegistry?
    private weak var ingestor: Ingestor?

    /// Observer handles for sleep/wake notifications (so we can re-arm).
    private var wakeObserver:       NSObjectProtocol?
    private var foregroundObserver: NSObjectProtocol?

    // MARK: - Path

    static var configURL: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".shiro", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("hooks.json")
    }

    // MARK: - Init

    init(coordinator: AgentCoordinator,
         skillsRegistry: SkillsRegistry,
         ingestor: Ingestor) {
        self.coordinator    = coordinator
        self.skillsRegistry = skillsRegistry
        self.ingestor       = ingestor
        writeDefaultsIfNeeded()
        load()
    }

    // MARK: - Lifecycle

    func start() {
        for hook in hooks where hook.enabled {
            switch hook.type {
            case "app_launch":
                fire(hook: hook, reason: "app_launch")
            case "file_watch":
                startFileWatch(hook: hook)
            case "schedule":
                startSchedule(hook: hook)
            default:
                print("[HooksEngine] unknown hook type: \(hook.type)")
            }
        }

        // Wake-aware re-scheduling: recompute every daily timer after sleep/wake
        // and whenever the app comes back to the foreground. Timers based on
        // DispatchSourceTimer with wall-clock deadlines survive sleep already,
        // but we re-arm defensively in case the system clock changed.
        let wsCenter = NSWorkspace.shared.notificationCenter
        wakeObserver = wsCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.rearmAllDailySchedules(reason: "wake") }
        }
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.rearmAllDailySchedules(reason: "foreground") }
        }

        let enabled  = hooks.filter { $0.enabled }
        let disabled = hooks.filter { !$0.enabled }
        print("[HooksEngine] \(enabled.count) hook(s) active: \(enabled.map(\.name).joined(separator: ", "))")
        if !disabled.isEmpty {
            print("[HooksEngine] \(disabled.count) hook(s) disabled (enable in ~/.shiro/hooks.json): \(disabled.map(\.name).joined(separator: ", "))")
        }
    }

    func stop() {
        fileWatchSources.values.forEach { $0.cancel() }
        fileWatchSources.removeAll()
        scheduleTimers.values.forEach { $0.invalidate() }
        scheduleTimers.removeAll()
        dailyTimers.values.forEach { $0.cancel() }
        dailyTimers.removeAll()
        dailySchedules.removeAll()

        if let w = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(w)
            wakeObserver = nil
        }
        if let f = foregroundObserver {
            NotificationCenter.default.removeObserver(f)
            foregroundObserver = nil
        }
    }

    /// Re-compute wall-clock deadlines for all remembered daily hooks.
    /// Called on sleep/wake and app-foreground events.
    private func rearmAllDailySchedules(reason: String) {
        for (name, timeStr) in dailySchedules {
            guard let hook = hooks.first(where: { $0.name == name && $0.enabled }) else { continue }
            scheduleNextDailyFire(hook: hook, timeStr: timeStr)
            print("[HooksEngine] re-armed daily hook '\(name)' (\(timeStr)) — reason: \(reason)")
        }
    }

    // MARK: - Load / Save

    func load() {
        let url = Self.configURL
        do {
            let data = try Data(contentsOf: url)
            let file = try JSONDecoder().decode(HooksFile.self, from: data)
            hooks = file.hooks
        } catch {
            print("[HooksEngine] load error: \(error.localizedDescription)")
        }
    }

    // MARK: - File Watch

    private func startFileWatch(hook: Hook) {
        guard let rawPath = hook.path else {
            print("[HooksEngine] file_watch hook '\(hook.name)' missing path")
            return
        }
        let path = (rawPath as NSString).expandingTildeInPath
        openWatcher(hook: hook, path: path)
    }

    /// Open a DispatchSource on `path` and remember it under `hook.name`.
    /// On rename/delete we tear down and re-arm so the hook keeps working
    /// when editors use atomic saves (rename-in-place) or delete+recreate.
    private func openWatcher(hook: Hook, path: String) {
        // Create file if it doesn't exist so we can open a descriptor.
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }

        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else {
            print("[HooksEngine] cannot watch \(path): open() failed")
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )
        // Capture the mask inside the handler so we can react to rename/delete.
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            let flags = source.data
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.fire(hook: hook, reason: "file_changed:\(path)")

                // Atomic-save editors (rename) and delete-then-create flows
                // invalidate the current fd; re-arm against the (new) path.
                if flags.contains(.rename) || flags.contains(.delete) {
                    self.rearmWatcher(hook: hook, path: path)
                }
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()

        fileWatchSources[hook.name] = source
        print("[HooksEngine] watching \(path) for hook '\(hook.name)'")
    }

    /// Cancel the current source, re-open the file, and create a new source.
    private func rearmWatcher(hook: Hook, path: String) {
        if let existing = fileWatchSources.removeValue(forKey: hook.name) {
            existing.cancel()
        }
        // Give the filesystem a moment to settle (rename → new inode exists).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.openWatcher(hook: hook, path: path)
        }
    }

    // MARK: - Schedule

    private func startSchedule(hook: Hook) {
        guard let schedule = hook.schedule else { return }

        if schedule.hasPrefix("every:"),
           let minutes = Int(schedule.dropFirst("every:".count)), minutes > 0 {
            // Interval timer
            let interval = TimeInterval(minutes * 60)
            let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.fire(hook: hook, reason: "schedule:every_\(minutes)m")
                }
            }
            scheduleTimers[hook.name] = timer

        } else if schedule.count == 5, schedule[schedule.index(schedule.startIndex, offsetBy: 2)] == ":" {
            // Daily time "HH:MM"
            scheduleNextDailyFire(hook: hook, timeStr: schedule)
        } else {
            print("[HooksEngine] unrecognised schedule format '\(schedule)' for hook '\(hook.name)'")
        }
    }

    private func scheduleNextDailyFire(hook: Hook, timeStr: String) {
        let parts = timeStr.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return }
        let targetHour = parts[0]
        let targetMin  = parts[1]

        let cal = Calendar.current
        var components = cal.dateComponents([.year, .month, .day], from: Date())
        components.hour   = targetHour
        components.minute = targetMin
        components.second = 0

        var fireDate = cal.date(from: components) ?? Date()
        if fireDate <= Date() {
            fireDate = cal.date(byAdding: .day, value: 1, to: fireDate) ?? fireDate
        }

        // Cancel any existing daily timer for this hook.
        dailyTimers.removeValue(forKey: hook.name)?.cancel()

        // DispatchSourceTimer with a WALL-clock deadline survives system sleep
        // — a plain Timer would have drifted by the sleep duration.
        let src = DispatchSource.makeTimerSource(queue: .main)
        let wallSeconds = fireDate.timeIntervalSinceNow
        src.schedule(wallDeadline: .now() + wallSeconds)
        src.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                self?.fire(hook: hook, reason: "schedule:\(timeStr)")
                // Reschedule for next day.
                self?.scheduleNextDailyFire(hook: hook, timeStr: timeStr)
            }
        }
        src.resume()

        dailyTimers[hook.name]    = src
        dailySchedules[hook.name] = timeStr
        let delay = max(0, wallSeconds)
        print("[HooksEngine] hook '\(hook.name)' fires at \(timeStr) (in \(Int(delay/60))m)")
    }

    // MARK: - Fire

    private func fire(hook: Hook, reason: String) {
        print("[HooksEngine] 🔔 firing hook '\(hook.name)' — reason: \(reason)")
        switch hook.action.type {
        case "skill":
            fireSkillAction(hook: hook)
        case "query":
            fireQueryAction(hook: hook)
        case "ingest":
            fireIngestAction(hook: hook)
        default:
            print("[HooksEngine] unknown action type '\(hook.action.type)'")
        }
    }

    private func fireSkillAction(hook: Hook) {
        guard let skillName = hook.action.skill,
              let skill = skillsRegistry?.skill(named: skillName) else {
            print("[HooksEngine] skill '\(hook.action.skill ?? "nil")' not found")
            return
        }
        let args = hook.action.args ?? [:]
        // Auto-inject date for daily-brief
        var resolvedArgs = args
        if resolvedArgs["date"] == nil {
            let f = DateFormatter(); f.dateStyle = .medium
            resolvedArgs["date"] = f.string(from: Date())
        }
        let prompt = skill.fillTemplate(args: resolvedArgs)
        Task {
            try? await coordinator?.send(query: prompt, systemPrompt: skill.systemPrompt)
        }
    }

    private func fireQueryAction(hook: Hook) {
        guard let query = hook.action.query, !query.isEmpty else { return }
        Task { try? await coordinator?.send(query: query) }
    }

    private func fireIngestAction(hook: Hook) {
        guard let rawPath = hook.action.path else { return }
        let path    = (rawPath as NSString).expandingTildeInPath
        let corpus  = hook.action.corpus ?? "docs"
        guard let ing = ingestor else { return }
        Task {
            do {
                let n = try await ing.ingestFile(path, corpus: corpus)
                print("[HooksEngine] ingest '\(path)' → \(n) chunks")
            } catch {
                print("[HooksEngine] ingest error: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Defaults

    private func writeDefaultsIfNeeded() {
        guard !FileManager.default.fileExists(atPath: Self.configURL.path) else { return }

        let collabPath = "~/Projects/shiro/COLLABORATION.md"
        let defaults = HooksFile(hooks: [
            Hook(
                name: "daily-brief",
                type: "schedule",
                path: nil,
                schedule: "09:00",
                action: HookAction(type: "skill", skill: "daily-brief",
                                   args: [:], query: nil, path: nil, corpus: nil),
                enabled: false,
                description: "Morning briefing every day at 09:00"
            ),
            Hook(
                name: "watch-collaboration",
                type: "file_watch",
                path: collabPath,
                schedule: nil,
                action: HookAction(type: "query", skill: nil, args: nil,
                                   query: "Shiromi updated COLLABORATION.md — please review and integrate new research notes.",
                                   path: nil, corpus: nil),
                enabled: true,
                description: "Notify when Shiromi adds notes to COLLABORATION.md"
            ),
            Hook(
                name: "ingest-on-launch",
                type: "app_launch",
                path: nil,
                schedule: nil,
                action: HookAction(type: "ingest", skill: nil, args: nil,
                                   query: nil, path: "~/Projects/shiro", corpus: "code"),
                enabled: false,
                description: "Re-index ~/Projects/shiro into memory on every launch"
            ),
            Hook(
                name: "watch-projects",
                type: "file_watch",
                path: "~/Projects",
                schedule: nil,
                action: HookAction(type: "ingest", skill: nil, args: nil,
                                   query: nil, path: "~/Projects", corpus: "code"),
                enabled: false,
                description: "Re-index ~/Projects whenever any file changes"
            ),
        ])

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(defaults) {
            try? data.write(to: Self.configURL, options: .atomic)
            print("[HooksEngine] created default hooks at \(Self.configURL.path)")
        }
        hooks = defaults.hooks
    }
}
