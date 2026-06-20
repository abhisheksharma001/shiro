import Foundation

// MARK: - Bridge Status

/// Granular bridge lifecycle state, published to the UI.
enum BridgeStatus: Equatable {
    case starting
    case running(routeLabel: String)
    case restarting(attempt: Int, maxAttempts: Int)
    case failingOver(from: Config.RouteMode, to: Config.RouteMode)
    case offline(reason: String)

    var isOnline: Bool {
        if case .running = self { return true }
        return false
    }

    var displayLabel: String {
        switch self {
        case .starting:                          return "Starting…"
        case .running(let label):                return label
        case .restarting(let a, let m):          return "Reconnecting (\(a)/\(m))…"
        case .failingOver(_, let to):            return "Switching to \(to.displayName)…"
        case .offline(let reason):               return "Offline — \(reason)"
        }
    }

    var symbolName: String {
        switch self {
        case .running:                           return "circle.fill"
        case .starting, .restarting, .failingOver: return "arrow.triangle.2.circlepath"
        case .offline:                           return "exclamationmark.circle.fill"
        }
    }
}

// MARK: - BridgeHealthMonitor

/// Watches the active BridgeRouter. On crash or hang:
///   1. Attempts up to `maxRestarts` hot-restarts of the same router.
///   2. If all fail, walks the fallback chain: claudeCode → anthropic → lmStudio.
///   3. If the entire chain is exhausted, reports `.offline`.
///
/// Thread model: @MainActor — same isolation as AppState and the routers.
@MainActor
final class BridgeHealthMonitor {

    // MARK: - Config

    private let maxRestarts: Int       = 3
    private let baseBackoffSeconds: Double = 2.0   // doubles each attempt

    // MARK: - State

    private(set) var status: BridgeStatus = .starting

    /// Callback fired on every status change — connect to AppState's @Published property.
    var onStatusChange: ((BridgeStatus) -> Void)?
    /// Callback fired when the monitor has a new router ready (AppState re-wires the coordinator).
    var onRouterReady:  ((any BridgeRouter) -> Void)?

    private var currentMode: Config.RouteMode = Config.routeMode
    private var restartCount: Int = 0
    private var monitorTask:  Task<Void, Never>?

    // Dependencies injected from AppState.
    private weak var appState: AppState?

    init(appState: AppState) {
        self.appState = appState
    }

    // MARK: - Start / Stop

    func attach(to router: any BridgeRouter, mode: Config.RouteMode) {
        currentMode  = mode
        restartCount = 0
        setStatus(.running(routeLabel: router.routeLabel))
        watchRouter(router)
    }

    func stop() {
        monitorTask?.cancel()
        monitorTask = nil
    }

    // MARK: - Watch

    private func watchRouter(_ router: any BridgeRouter) {
        monitorTask?.cancel()
        let prev = router.onEvent          // preserve existing handler
        router.onEvent = { [weak self] event in
            prev?(event)                    // pass through to coordinator first
            if case .bridgeError(_, let msg) = event,
               msg.contains("exited") || msg.contains("not running") {
                Task { @MainActor [weak self] in
                    self?.handleCrash(currentMode: self?.currentMode ?? .lmStudio)
                }
            }
        }
    }

    // MARK: - Crash handling

    private func handleCrash(currentMode: Config.RouteMode) {
        guard let appState else { return }
        restartCount += 1

        if restartCount <= maxRestarts {
            setStatus(.restarting(attempt: restartCount, maxAttempts: maxRestarts))
            let delay = baseBackoffSeconds * pow(2.0, Double(restartCount - 1))
            print("[BridgeHealth] restart \(restartCount)/\(maxRestarts) in \(Int(delay))s — mode: \(currentMode.rawValue)")
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                await self?.attemptRestart(mode: currentMode, appState: appState)
            }
        } else {
            restartCount = 0
            startFailover(from: currentMode, appState: appState)
        }
    }

    private func attemptRestart(mode: Config.RouteMode, appState: AppState) async {
        guard let router = await appState.buildRouter(for: mode) else {
            handleCrash(currentMode: mode)
            return
        }
        do {
            try router.launch()
            restartCount = 0
            onRouterReady?(router)
            setStatus(.running(routeLabel: router.routeLabel))
            watchRouter(router)
            print("[BridgeHealth] ✅ restarted \(mode.rawValue)")
        } catch {
            print("[BridgeHealth] restart failed: \(error.localizedDescription)")
            handleCrash(currentMode: mode)
        }
    }

    // MARK: - Failover chain

    private func startFailover(from mode: Config.RouteMode, appState: AppState) {
        let chain: [Config.RouteMode] = [.claudeCode, .anthropic, .lmStudio]
        let remaining = chain.drop(while: { $0 != mode }).dropFirst()

        guard let next = remaining.first(where: { canUse($0) }) else {
            setStatus(.offline(reason: "All backends failed. Check Settings → Route."))
            print("[BridgeHealth] ❌ All backends exhausted")
            return
        }

        setStatus(.failingOver(from: mode, to: next))
        print("[BridgeHealth] failing over: \(mode.rawValue) → \(next.rawValue)")

        Task { [weak self] in
            guard let self else { return }
            guard let router = await appState.buildRouter(for: next) else {
                self.setStatus(.offline(reason: "Could not build \(next.rawValue) router"))
                return
            }
            do {
                try router.launch()
                self.currentMode  = next
                self.restartCount = 0
                Config.setRouteMode(next)
                self.onRouterReady?(router)
                self.setStatus(.running(routeLabel: router.routeLabel))
                self.watchRouter(router)
                print("[BridgeHealth] ✅ failed over to \(next.rawValue)")
            } catch {
                print("[BridgeHealth] failover to \(next.rawValue) also failed: \(error)")
                self.startFailover(from: next, appState: appState)
            }
        }
    }

    private func canUse(_ mode: Config.RouteMode) -> Bool {
        switch mode {
        case .claudeCode: return Config.claudeCodeCLIAvailable
        case .anthropic:  return Config.anthropicEnabled
        case .lmStudio:   return true   // always available (may just be offline/slow)
        }
    }

    // MARK: - Helpers

    private func setStatus(_ s: BridgeStatus) {
        status = s
        onStatusChange?(s)
    }
}
