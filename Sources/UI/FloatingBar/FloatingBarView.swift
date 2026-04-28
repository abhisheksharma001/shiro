/*
 AESTHETIC: Claude — Editorial Warmth
 ────────────────────────────────────
 A direct homage to the visual identity of Anthropic's Claude apps:
 warm charcoals (not cold blues), Claude's signature copper accent,
 cream text, and an editorial typographic voice (serif for display
 moments, SF Pro for prose, JetBrains Mono only for code/IDs).

 BG:        #1A1916  (warm charcoal — Claude chat surface)
 Sidebar:   #211E1B  (slightly raised warm)
 Surface:   #25221E  (assistant bubble)
 Elevated:  #2E2A26  (hover, focus)
 Border:    #3A3530  (subtle warm hairline)
 Accent:    #D97757  (CLAUDE COPPER — Anthropic's signature warm orange)
 Active:    #B8946A  (warm gold — running / success)
 Amber:     #D4A574  (thinking, warning)
 Red:       #D86553  (error — warm-tinted)
 Text:      #F2EDE5  (warm cream, not cold white)
 Muted:     #8B847C  (warm gray)
 DimMuted:  #5C544C  (placeholder text)

 Type:      "New York" / Charter (system serif) — display headings, wordmark
            SF Pro Text — body, UI labels
            JetBrains Mono — code, route labels, technical badges only

 Layout:    Generous whitespace, light hairlines, soft 12-14pt corners.
            Asymmetry: input bar weighted left; tools/agents right.
*/

import SwiftUI
import MarkdownUI

// MARK: - Palette  (Claude — Editorial Warmth)

extension Color {
    // — Backgrounds —
    static let vBg       = Color(hex: "#1A1916")   // warm charcoal
    static let vSidebar  = Color(hex: "#211E1B")
    static let vSurface  = Color(hex: "#25221E")
    static let vElev     = Color(hex: "#2E2A26")
    // — Lines —
    static let vBorder   = Color(hex: "#3A3530")
    static let vBorderHi = Color(hex: "#4A433D")
    // — Accents —
    static let vAccent   = Color(hex: "#D97757")   // Claude copper
    static let vAccent2  = Color(hex: "#C8845F")   // hover/pressed
    static let vActive   = Color(hex: "#B8946A")   // warm gold (running)
    static let vAmber    = Color(hex: "#D4A574")
    static let vRed      = Color(hex: "#D86553")
    // — Text —
    static let vText     = Color(hex: "#F2EDE5")   // warm cream
    static let vMuted    = Color(hex: "#8B847C")
    static let vDim      = Color(hex: "#5C544C")
}

// MARK: - Type system

enum ShiroFont {
    /// Editorial serif (system "New York" on macOS) — for wordmarks + display headings.
    static func serif(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }
    /// SF Pro Text — body, prose, UI labels.
    static func ui(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
    /// JetBrains Mono — code, route labels, technical badges, IDs.
    static func mono(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .custom("JetBrains Mono", size: size).weight(weight)
    }
}

// MARK: - FloatingBarView

struct FloatingBarView: View {
    @EnvironmentObject var appState: AppState
    @State private var inputText:   String = ""
    @State private var isTyping:    Bool   = false
    @State private var currentSendId: UUID? = nil
    @FocusState private var inputFocused: Bool

    // Computed alias into shared conversation
    private var messages: [DisplayMessage] { appState.conversationMessages }

    /// Single source of truth — drives both this view AND the NSPanel frame
    /// (FloatingBarWindowController observes the same property via Combine).
    private var isExpanded: Bool {
        get { appState.isFloatingExpanded }
    }

    var body: some View {
        VStack(spacing: 8) {
            // Approval overlays float above the bar
            if let gate = appState.consentGate, !gate.pendingApprovals.isEmpty {
                ApprovalQueueOverlay(gate: gate)
            }

            ZStack {
                RoundedRectangle(cornerRadius: isExpanded ? 18 : 32)
                    .fill(Color.vBg)
                    .overlay(
                        RoundedRectangle(cornerRadius: isExpanded ? 18 : 32)
                            .strokeBorder(Color.vBorder, lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.7), radius: 24, y: 6)

                VStack(spacing: 0) {
                    compactBar

                    if appState.isMeetingMode {
                        divider
                        MeetingModeView { _ in collapse() }
                    } else if isExpanded {
                        divider
                        chatPanel
                    }
                }
            }
        }
        .padding(.horizontal, 0)
        .onAppear { checkConnectivity() }
    }

    // MARK: - Compact Bar (always visible, 60pt)

    private var compactBar: some View {
        HStack(spacing: 10) {
            // State orb
            stateOrb

            // Route label pill
            routePill

            // Quick input
            ZStack(alignment: .leading) {
                if inputText.isEmpty {
                    Text(placeholder)
                        .font(.custom("JetBrains Mono", size: 12.5))
                        .foregroundColor(.vMuted)
                }
                TextField("", text: $inputText)
                    .font(.custom("JetBrains Mono", size: 12.5))
                    .foregroundColor(.vText)
                    .textFieldStyle(.plain)
                    .focused($inputFocused)
                    .onSubmit { sendMessage() }
                    .onChange(of: inputFocused) { _, focused in
                        let want = focused || !messages.isEmpty
                        if appState.isFloatingExpanded != want {
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                                appState.isFloatingExpanded = want
                            }
                        }
                    }
            }

            HStack(spacing: 6) {
                // Sub-agent badge
                if !appState.subAgentSessions.isEmpty {
                    subAgentBadge
                }

                // Meeting toggle
                barButton(
                    icon: appState.isMeetingMode ? "waveform.circle.fill" : "waveform.circle",
                    color: appState.isMeetingMode ? .vAmber : .vMuted
                ) {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        appState.isMeetingMode.toggle()
                        if appState.isMeetingMode { appState.isFloatingExpanded = true }
                    }
                }
                .help(appState.isMeetingMode ? "Exit meeting mode" : "Meeting mode")

                // Mic
                if !appState.isMeetingMode {
                    barButton(
                        icon: appState.isListening ? "mic.fill" : "mic",
                        color: appState.isListening ? .vActive : .vMuted
                    ) { appState.toggleListening() }
                    .help(appState.isListening ? "Stop mic" : "Push to talk")
                }

                // Send / Stop
                if appState.isProcessing {
                    barButton(icon: "stop.circle.fill", color: .vRed) { stopProcessing() }
                        .help("Stop")
                } else if !inputText.isEmpty {
                    barButton(icon: "arrow.up.circle.fill", color: .vAccent) { sendMessage() }
                        .help("Send")
                }

                // Clear chat
                if !messages.isEmpty && !appState.isProcessing {
                    barButton(icon: "trash", color: .vMuted) { appState.clearConversation() }
                        .help("Clear conversation")
                }

                // Expand to main window
                barButton(icon: "arrow.up.left.and.arrow.down.right", color: .vMuted) {
                    ShiroMainWindowController.shared.show()
                }
                .help("Open full Shiro workspace")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 60)
    }

    // MARK: - Chat Panel (expanded, scrollable)

    private var chatPanel: some View {
        // FIXED height — never let SwiftUI grow the panel based on content,
        // because the NSPanel auto-resizes against this and we get an
        // NSISEngine constraint feedback loop → stack-overflow crash.
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(messages) { msg in
                            MessageBubble(message: msg)
                                .id(msg.id)
                        }
                        if isTyping {
                            TypingDots()
                                .padding(.leading, 16)
                                .id("typing-indicator")
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                }
                .frame(height: 440)               // fixed, NOT maxHeight
                .onChange(of: messages.count) { _, _ in
                    withAnimation { proxy.scrollTo(messages.last?.id) }
                }
                .onChange(of: isTyping) { _, v in
                    if v { withAnimation { proxy.scrollTo("typing-indicator") } }
                }
            }

            // Status line when processing
            if appState.isProcessing {
                HStack(spacing: 6) {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 5))
                        .foregroundColor(.vAmber)
                    Text(appState.agentStatus.label)
                        .font(.custom("JetBrains Mono", size: 10.5))
                        .foregroundColor(.vMuted)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
                .frame(height: 22)
            } else {
                Spacer().frame(height: 8)
            }
        }
        .frame(height: 472)                       // total = 440 + 32 footer
    }

    // MARK: - State Orb

    private var stateOrb: some View {
        ZStack {
            if appState.isProcessing {
                Circle()
                    .fill(orbColor.opacity(0.18))
                    .frame(width: 26, height: 26)
                    .scaleEffect(1.3)
                    .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true),
                               value: appState.isProcessing)
            }
            Circle()
                .fill(orbColor)
                .frame(width: 10, height: 10)
        }
        .frame(width: 26, height: 26)
        .help(appState.agentStatus.label)
    }

    private var orbColor: Color {
        switch appState.agentStatus {
        case .idle:      return .vMuted
        case .listening: return .vActive
        case .thinking:  return .vAccent
        case .acting:    return .vAmber
        case .speaking:  return .vActive
        case .error:     return .vRed
        }
    }

    // MARK: - Route Pill

    private var routePill: some View {
        Text(routeShortLabel)
            .font(.custom("JetBrains Mono", size: 9.5))
            .foregroundColor(routePillColor)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(routePillColor.opacity(0.12))
            .overlay(
                Capsule().strokeBorder(routePillColor.opacity(0.35), lineWidth: 0.8)
            )
            .clipShape(Capsule())
    }

    private var routeShortLabel: String {
        switch appState.activeRouteMode {
        case .claudeCode: return "claude-cli"
        case .anthropic:  return "api"
        case .lmStudio:   return "local"
        }
    }

    private var routePillColor: Color {
        switch appState.bridgeStatus {
        case .running:           return .vActive
        case .starting:          return .vAmber
        case .restarting:        return .vAmber
        case .failingOver:       return .vAmber
        case .offline:           return .vRed
        }
    }

    // MARK: - Sub-agent Badge

    private var subAgentBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: "cpu")
                .font(.system(size: 9, weight: .semibold))
            Text("\(appState.subAgentSessions.count)")
                .font(.custom("JetBrains Mono", size: 9.5))
        }
        .foregroundColor(.vAccent)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Color.vAccent.opacity(0.12))
        .clipShape(Capsule())
        .help("\(appState.subAgentSessions.count) sub-agent(s) running")
    }

    // MARK: - Helpers

    private var placeholder: String {
        // Surface bridge problems immediately rather than showing a generic prompt.
        switch appState.bridgeStatus {
        case .offline(let reason): return "⚠  bridge offline — \(reason)"
        case .restarting:           return "↻ restarting bridge…"
        case .failingOver:          return "↻ failing over backend…"
        case .starting:             return "starting bridge…"
        case .running:              break
        }
        switch appState.activeRouteMode {
        case .claudeCode: return "Ask Shiro · via Claude CLI · type /  to use a skill"
        case .anthropic:  return "Ask Shiro · via Anthropic API · /forecast /research /ingest …"
        case .lmStudio:
            return appState.lmStudioConnected
                ? "Ask Shiro · local LM Studio · /forecast /research …"
                : "⚠  LM Studio not connected — open Settings → Route"
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.vBorder)
            .frame(height: 1)
            .padding(.horizontal, 12)
    }

    private func collapse() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            appState.isFloatingExpanded = false
        }
    }

    // MARK: - Actions

    private func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let coordinator = appState.agentCoordinator else { return }
        inputText = ""

        var queryText              = text
        var systemPromptOverride: String? = nil

        if text.hasPrefix("/"),
           let registry = appState.skillsRegistry,
           let resolved = registry.resolve(input: text) {
            queryText             = resolved.prompt
            systemPromptOverride  = resolved.skill.systemPrompt
            appState.conversationMessages.append(
                DisplayMessage(role: .user, content: text, badge: "[\(resolved.skill.name)]")
            )
        } else {
            appState.conversationMessages.append(DisplayMessage(role: .user, content: text))
        }

        // Streaming assistant bubble (empty — fills via token callbacks)
        appState.conversationMessages.append(DisplayMessage(role: .assistant, content: ""))
        isTyping             = true
        appState.isProcessing = true
        appState.agentStatus  = .thinking
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            appState.isFloatingExpanded = true
        }

        let reqId = UUID()
        currentSendId = reqId

        coordinator.onStreamingToken = { [weak appState] token in
            guard let appState else { return }
            guard appState.conversationMessages.last?.role == .assistant else { return }
            let idx = appState.conversationMessages.indices.last!
            appState.conversationMessages[idx].content += token
        }

        coordinator.onTurnComplete = { [weak appState] _ in
            Task { @MainActor in
                isTyping               = false    // @State, safe on main actor
                appState?.isProcessing = false
                appState?.agentStatus  = .idle
                coordinator.onStreamingToken = nil
                coordinator.onTurnComplete   = nil
                await appState?.refreshSubAgentSessions()
            }
        }

        Task {
            do {
                _ = try await coordinator.send(query: queryText, systemPrompt: systemPromptOverride)
            } catch {
                isTyping                   = false
                appState.isProcessing      = false
                appState.agentStatus       = .error(error.localizedDescription)
                if appState.conversationMessages.last?.role == .assistant {
                    let idx = appState.conversationMessages.indices.last!
                    appState.conversationMessages[idx].content = "❌ \(error.localizedDescription)"
                }
            }
        }
    }

    private func stopProcessing() {
        appState.agentCoordinator?.bridge?.interrupt(sessionKey: "main")
        appState.acpBridge?.interrupt(sessionKey: "main")
        appState.isProcessing = false
        appState.agentStatus  = .idle
        isTyping              = false
    }

    private func checkConnectivity() {
        Task {
            let ok = await appState.lmStudio?.healthCheck() ?? false
            appState.lmStudioConnected = ok
        }
    }

    private func barButton(icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(color)
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Message Bubble

struct MessageBubble: View {
    let message: DisplayMessage

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if message.role == .user {
                Spacer(minLength: 64)
                VStack(alignment: .trailing, spacing: 4) {
                    Text(message.content)
                        .font(ShiroFont.ui(size: 12.5))
                        .foregroundColor(Color.vBg)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 9)
                        .background(Color.vAccent)
                        .clipShape(
                            UnevenRoundedRectangle(
                                topLeadingRadius: 14, bottomLeadingRadius: 14,
                                bottomTrailingRadius: 14, topTrailingRadius: 4,
                                style: .continuous
                            )
                        )
                    if let badge = message.badge {
                        Text(badge)
                            .font(ShiroFont.mono(size: 9))
                            .foregroundColor(.vAccent.opacity(0.75))
                    }
                }
            } else if message.role == .assistant {
                VStack(alignment: .leading, spacing: 6) {
                    // Wordmark — serif "Shiro" in copper
                    HStack(spacing: 5) {
                        Circle().fill(Color.vAccent).frame(width: 5, height: 5)
                        Text("Shiro")
                            .font(ShiroFont.serif(size: 11, weight: .semibold))
                            .foregroundColor(.vAccent)
                    }

                    if message.content.isEmpty {
                        TypingDots()
                    } else {
                        Markdown(message.content)
                            .markdownTheme(.shiroTheme)
                            .font(ShiroFont.ui(size: 12.5))
                            .foregroundColor(.vText)
                    }

                    // Tool calls inline
                    if !message.toolCalls.isEmpty {
                        ForEach(message.toolCalls) { call in
                            ToolCallChip(call: call)
                        }
                    }
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 10)
                .background(Color.vSurface)
                .clipShape(
                    UnevenRoundedRectangle(
                        topLeadingRadius: 4, bottomLeadingRadius: 14,
                        bottomTrailingRadius: 14, topTrailingRadius: 14,
                        style: .continuous
                    )
                )
                Spacer(minLength: 64)
            }
        }
    }
}

// MARK: - Tool Call Chip

struct ToolCallChip: View {
    let call: ToolCallInfo

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: call.isRunning ? "arrow.triangle.2.circlepath" : (call.isError ? "xmark.circle" : "checkmark.circle"))
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(call.isRunning ? .vAmber : (call.isError ? .vRed : .vActive))
                .rotationEffect(call.isRunning ? .degrees(360) : .degrees(0))
                .animation(call.isRunning ? .linear(duration: 1).repeatForever(autoreverses: false) : .default,
                           value: call.isRunning)

            Text(call.name)
                .font(.custom("JetBrains Mono", size: 10))
                .foregroundColor(.vMuted)

            if let output = call.output {
                Text(output.prefix(60))
                    .font(.custom("JetBrains Mono", size: 10))
                    .foregroundColor(.vText.opacity(0.7))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Color.vBorder.opacity(0.6))
        .cornerRadius(6)
    }
}

// MARK: - Typing Dots

struct TypingDots: View {
    @State private var phase: Int = 0
    private let timer = Timer.publish(every: 0.35, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3) { i in
                Circle()
                    .fill(Color.vAccent.opacity(i == phase ? 1 : 0.3))
                    .frame(width: 5, height: 5)
                    .scaleEffect(i == phase ? 1.25 : 1.0)
                    .animation(.easeInOut(duration: 0.2), value: phase)
            }
        }
        .onReceive(timer) { _ in phase = (phase + 1) % 3 }
    }
}

// MARK: - Settings View (launched from ShiroApp Settings scene)

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            StatusTab()
                .tabItem { Label("Status", systemImage: "circle.fill") }
                .tag(0)
            RouteModeTab()
                .tabItem { Label("Route", systemImage: "arrow.triangle.branch") }
                .tag(1)
            APIKeysTab()
                .tabItem { Label("API Keys", systemImage: "key.fill") }
                .tag(2)
            MCPTab()
                .tabItem { Label("MCP Servers", systemImage: "server.rack") }
                .tag(3)
            UIPrefsTab()
                .tabItem { Label("Layout", systemImage: "rectangle.3.group") }
                .tag(4)
        }
        .frame(width: 580, height: 520)
        .padding(8)
        .environmentObject(appState)
    }
}

// MARK: Route Mode tab

private struct RouteModeTab: View {
    @EnvironmentObject var appState: AppState
    @State private var selected: Config.RouteMode = Config.routeMode
    @State private var allowedDirs: [String] = Config.allowedDirectories
    @State private var newDir:    String = ""
    @State private var switching  = false
    @State private var statusMsg: String?

    var body: some View {
        Form {
            Section("Active backend") {
                LabeledContent("Current", value: appState.activeRouteMode.displayName)
                LabeledContent("Running", value: (appState.bridgeRouter?.isRunning ?? false) ? "✅ Yes" : "❌ No")
            }
            Section("Switch backend") {
                Picker("Mode", selection: $selected) {
                    ForEach(Config.RouteMode.allCases) { m in
                        Text(m.displayName).tag(m)
                    }
                }
                .pickerStyle(.radioGroup)
                Text(modeHint(selected)).font(.system(size: 11)).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if selected == .claudeCode {
                    LabeledContent("Claude CLI", value: Config.claudeCodeCLIAvailable ? "✅ Found" : "❌ Not installed")
                        .font(.system(size: 11))
                }
                HStack {
                    Spacer()
                    if let msg = statusMsg {
                        Text(msg).font(.system(size: 11)).foregroundColor(.green)
                    }
                    Button(switching ? "Switching…" : "Apply") { Task { await apply() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(switching || selected == appState.activeRouteMode)
                }
            }
            Section("PC access — directories for Claude CLI (--add-dir)") {
                Text("Each entry lets the CLI read and write that directory.")
                    .font(.system(size: 11)).foregroundColor(.secondary)
                ForEach(allowedDirs.indices, id: \.self) { i in
                    HStack {
                        Text(allowedDirs[i]).font(.system(size: 12, design: .monospaced)).lineLimit(1)
                        Spacer()
                        Button(role: .destructive) {
                            allowedDirs.remove(at: i)
                            Config.setAllowedDirectories(allowedDirs)
                        } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain)
                    }
                }
                HStack {
                    TextField("/absolute/path or ~/Folder", text: $newDir)
                        .textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced))
                    Button("Add") {
                        let exp = (newDir as NSString).expandingTildeInPath
                        guard !exp.isEmpty, !allowedDirs.contains(exp) else { return }
                        allowedDirs.append(exp)
                        Config.setAllowedDirectories(allowedDirs)
                        newDir = ""
                    }
                }
                Button("Grant full ~/ access") {
                    allowedDirs = [NSHomeDirectory()]
                    Config.setAllowedDirectories(allowedDirs)
                }.font(.system(size: 11))
            }
        }
        .formStyle(.grouped)
    }

    private func modeHint(_ m: Config.RouteMode) -> String {
        switch m {
        case .lmStudio:   return "Fully local, free. Uses LM Studio + Shiro tools (SQL, memory, skills)."
        case .anthropic:  return "Your own API key (sk-ant-…). Real Claude, billed per-token."
        case .claudeCode: return "Your Claude Pro/Max subscription via the local `claude` CLI. Requires `claude` installed & logged in."
        }
    }

    private func apply() async {
        switching = true; defer { switching = false }
        await appState.switchRouteMode(selected)
        statusMsg = "Switched to \(selected.displayName)"
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        statusMsg = nil
    }
}

// MARK: Status tab

private struct StatusTab: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Form {
            Section("LLM Backend") {
                LabeledContent("Active route", value: appState.activeRouteMode.displayName)
                LabeledContent("Bridge running", value: (appState.bridgeRouter?.isRunning ?? false) ? "✅ Yes" : "❌ No")
                switch appState.activeRouteMode {
                case .claudeCode:
                    LabeledContent("Claude CLI",  value: Config.claudeCodeCLIAvailable ? "✅ Found" : "❌ Missing")
                    LabeledContent("PC access",   value: Config.allowedDirectories.first ?? "~")
                case .anthropic:
                    LabeledContent("API key",     value: Config.anthropicEnabled ? "✅ Set" : "❌ Missing")
                case .lmStudio:
                    LabeledContent("LM Studio",   value: appState.lmStudioConnected ? "✅ Connected" : "❌ Disconnected")
                    LabeledContent("Brain model", value: Config.brainModel)
                    LabeledContent("Fast model",  value: Config.fastModel)
                    LabeledContent("Embed model", value: Config.embeddingModel)
                }
            }
            Section("Services") {
                LabeledContent("Deepgram STT",  value: Config.deepgramEnabled ? "✅ Active" : "⚪ Whisper fallback")
                LabeledContent("Telegram",      value: Config.telegramEnabled ? "✅ Active" : "⚪ Off")
                LabeledContent("Memory Store",  value: appState.memoryStore   != nil ? "✅ Ready" : "⚪ Unavailable")
                LabeledContent("Skills",        value: "\(appState.skillsRegistry?.skills.count ?? 0) loaded")
                LabeledContent("Hooks",         value: "\(appState.hooksEngine?.hooks.filter(\.enabled).count ?? 0) active")
            }
            Section("Sub-agents") {
                LabeledContent("Active",    value: "\(appState.subAgentSessions.count)")
                LabeledContent("Completed", value: "\(appState.subAgentCompletedCount)")
                LabeledContent("Failed",    value: "\(appState.subAgentFailedCount)")
            }
        }
        .formStyle(.grouped)
        .task { await appState.refreshSubAgentSessions() }
    }
}

// MARK: API Keys tab

private struct APIKeysTab: View {
    @State private var anthropicKey:   String = KeychainHelper.get(.anthropicAPIKey)   ?? ""
    @State private var deepgramKey:    String = KeychainHelper.get(.deepgramAPIKey)    ?? ""
    @State private var telegramToken:  String = KeychainHelper.get(.telegramBotToken)  ?? ""
    @State private var telegramChatId: String = KeychainHelper.get(.telegramChatId)    ?? ""
    @State private var openAIKey:      String = KeychainHelper.get(.openAIAPIKey)      ?? ""
    @State private var openAIBase:     String = KeychainHelper.get(.openAIBaseURL)     ?? ""
    @State private var composioKey:    String = KeychainHelper.get(.composioAPIKey)    ?? ""
    @State private var githubToken:    String = KeychainHelper.get(.githubToken)       ?? ""
    @State private var hfToken:        String = KeychainHelper.get(.huggingFaceToken)  ?? ""
    @State private var saved = false

    var body: some View {
        ScrollView {
            Form {
                Section {
                    Text("All keys are stored in your macOS Keychain — never on disk in plain text.")
                        .font(.system(size: 11)).foregroundColor(.secondary)
                }
                Section("Anthropic (BYOK)") {
                    SecureTextField("sk-ant-…", text: $anthropicKey)
                    if !anthropicKey.isEmpty {
                        Text(anthropicKey.hasPrefix("sk-ant-") ? "✅ Valid format" : "⚠️ Should start with sk-ant-")
                            .font(.system(size: 11))
                            .foregroundColor(anthropicKey.hasPrefix("sk-ant-") ? .green : .orange)
                    }
                }
                Section("Deepgram STT") {
                    SecureTextField("Deepgram API key…", text: $deepgramKey)
                }
                Section("Telegram (remote approvals)") {
                    SecureTextField("Bot token from @BotFather…", text: $telegramToken)
                    TextField("Your chat ID from @userinfobot…", text: $telegramChatId).textFieldStyle(.roundedBorder)
                }
                Section("OpenAI-compatible endpoint") {
                    SecureTextField("API key (or 'local' for no auth)…", text: $openAIKey)
                    TextField("Base URL (e.g. http://localhost:1234/v1)…", text: $openAIBase).textFieldStyle(.roundedBorder)
                }
                Section("Composio  ▸  250+ integrations (Gmail, Slack, Notion, …)") {
                    SecureTextField("Composio API key…", text: $composioKey)
                    Link("Get one at app.composio.dev",
                         destination: URL(string: "https://app.composio.dev/")!)
                        .font(.system(size: 11))
                    Text("Enable the 'composio' MCP server in the MCP Servers tab after saving.")
                        .font(.system(size: 11)).foregroundColor(.secondary)
                }
                Section("GitHub  ▸  repo / gist / org access") {
                    SecureTextField("Personal access token (ghp_…)", text: $githubToken)
                    Link("Create a token at github.com/settings/tokens",
                         destination: URL(string: "https://github.com/settings/tokens")!)
                        .font(.system(size: 11))
                    Text("Scopes recommended: repo, read:org, gist, read:user.")
                        .font(.system(size: 11)).foregroundColor(.secondary)
                }
                Section("Hugging Face  ▸  hub access") {
                    SecureTextField("HF token (hf_…)", text: $hfToken)
                    Link("Create one at huggingface.co/settings/tokens",
                         destination: URL(string: "https://huggingface.co/settings/tokens")!)
                        .font(.system(size: 11))
                }
                Section {
                    HStack {
                        Spacer()
                        if saved {
                            Label("Saved!", systemImage: "checkmark.circle.fill")
                                .foregroundColor(.green).font(.system(size: 12))
                        }
                        Button("Save to Keychain") { saveAll() }.buttonStyle(.borderedProminent)
                    }
                    Text("Most key changes apply to the next bridge restart — toggle the route in the Route tab to apply immediately.")
                        .font(.system(size: 10.5)).foregroundColor(.secondary)
                }
            }
            .formStyle(.grouped)
        }
    }

    private func saveAll() {
        KeychainHelper.set(anthropicKey,   for: .anthropicAPIKey)
        KeychainHelper.set(deepgramKey,    for: .deepgramAPIKey)
        KeychainHelper.set(telegramToken,  for: .telegramBotToken)
        KeychainHelper.set(telegramChatId, for: .telegramChatId)
        KeychainHelper.set(openAIKey,      for: .openAIAPIKey)
        KeychainHelper.set(openAIBase,     for: .openAIBaseURL)
        KeychainHelper.set(composioKey,    for: .composioAPIKey)
        KeychainHelper.set(githubToken,    for: .githubToken)
        KeychainHelper.set(hfToken,        for: .huggingFaceToken)
        saved = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { saved = false }
    }
}

private struct SecureTextField: View {
    let placeholder: String
    @Binding var text: String
    @State private var isVisible = false
    init(_ placeholder: String, text: Binding<String>) { self.placeholder = placeholder; self._text = text }
    var body: some View {
        HStack {
            if isVisible { TextField(placeholder, text: $text).textFieldStyle(.roundedBorder) }
            else          { SecureField(placeholder, text: $text).textFieldStyle(.roundedBorder) }
            Button { isVisible.toggle() } label: {
                Image(systemName: isVisible ? "eye.slash" : "eye").foregroundColor(.secondary)
            }.buttonStyle(.plain)
        }
    }
}

// MARK: MCP tab

private struct MCPTab: View {
    @EnvironmentObject var appState: AppState
    var body: some View {
        Form {
            Section("MCP Servers  (\(appState.mcpRegistry?.enabledCount ?? 0) enabled)") {
                if let registry = appState.mcpRegistry {
                    ForEach(registry.servers) { server in
                        HStack(spacing: 8) {
                            Circle().fill(server.enabled ? Color.vActive : Color.vBorder).frame(width: 7, height: 7)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(server.name).font(.custom("JetBrains Mono", size: 12))
                                if let desc = server.description {
                                    Text(desc).font(.system(size: 10)).foregroundColor(.secondary).lineLimit(1)
                                }
                            }
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { server.enabled },
                                set: { registry.setEnabled(server.name, enabled: $0) }
                            ))
                            .labelsHidden().toggleStyle(.switch).scaleEffect(0.8)
                        }
                    }
                    Text("Config: ~/.shiro/mcp.json  •  Changes apply on next restart")
                        .font(.custom("JetBrains Mono", size: 10)).foregroundColor(.secondary).padding(.top, 4)
                } else {
                    Text("Loading…").foregroundColor(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: UI Preferences tab

private struct UIPrefsTab: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Form {
            Section("Layout") {
                Toggle("Show agents panel", isOn: $appState.uiShowAgentsPanel)
                    .onChange(of: appState.uiShowAgentsPanel) { _, _ in appState.saveUIPreferences() }
                Toggle("Show tool feed panel", isOn: $appState.uiShowToolFeed)
                    .onChange(of: appState.uiShowToolFeed) { _, _ in appState.saveUIPreferences() }
            }
            Section("Sub-agent display style") {
                Picker("Style", selection: $appState.uiSubAgentStyle) {
                    ForEach(SubAgentDisplayStyle.allCases, id: \.self) { style in
                        Text(style.label).tag(style)
                    }
                }
                .pickerStyle(.radioGroup)
                .onChange(of: appState.uiSubAgentStyle) { _, _ in appState.saveUIPreferences() }
                Text("Inline: sub-agent activity appears inside the chat thread.\nPanel: dedicated side panel with agent cards.\nTree: collapsible tree showing the agent hierarchy.")
                    .font(.system(size: 11)).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("Browser Control") {
                Toggle("Enable continuous screen capture", isOn: Binding(
                    get:  { appState.browserControlEnabled },
                    set:  { appState.setBrowserControl($0) }
                ))
                Text("When enabled, Shiro captures your screen periodically and can use that context to assist you. Requires Screen Recording permission.")
                    .font(.system(size: 11)).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let summary = appState.latestScreenSummary {
                    LabeledContent("Last capture", value: summary)
                        .font(.system(size: 11))
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Color / Corner helpers (shared)

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int = UInt64()
        Scanner(string: hex).scanHexInt64(&int)
        let r = Double((int >> 16) & 0xFF) / 255
        let g = Double((int >> 8)  & 0xFF) / 255
        let b = Double( int        & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}

extension View {
    func vCornerRadius(_ radius: CGFloat, corners: VRectCorner) -> some View {
        clipShape(VRoundedCornerShape(radius: radius, corners: corners))
    }
}

struct VRectCorner: OptionSet {
    let rawValue: Int
    static let topLeft     = VRectCorner(rawValue: 1 << 0)
    static let topRight    = VRectCorner(rawValue: 1 << 1)
    static let bottomLeft  = VRectCorner(rawValue: 1 << 2)
    static let bottomRight = VRectCorner(rawValue: 1 << 3)
    static let all: VRectCorner = [.topLeft, .topRight, .bottomLeft, .bottomRight]
}

struct VRoundedCornerShape: Shape {
    var radius: CGFloat
    var corners: VRectCorner
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let tl: CGFloat = corners.contains(.topLeft)     ? radius : 0
        let tr: CGFloat = corners.contains(.topRight)    ? radius : 0
        let bl: CGFloat = corners.contains(.bottomLeft)  ? radius : 0
        let br: CGFloat = corners.contains(.bottomRight) ? radius : 0
        path.move(to: CGPoint(x: rect.minX + tl, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - tr, y: rect.minY))
        path.addArc(center: CGPoint(x: rect.maxX - tr, y: rect.minY + tr), radius: tr,
                    startAngle: .degrees(-90), endAngle: .degrees(0),   clockwise: false)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - br))
        path.addArc(center: CGPoint(x: rect.maxX - br, y: rect.maxY - br), radius: br,
                    startAngle: .degrees(0),   endAngle: .degrees(90),  clockwise: false)
        path.addLine(to: CGPoint(x: rect.minX + bl, y: rect.maxY))
        path.addArc(center: CGPoint(x: rect.minX + bl, y: rect.maxY - bl), radius: bl,
                    startAngle: .degrees(90),  endAngle: .degrees(180), clockwise: false)
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + tl))
        path.addArc(center: CGPoint(x: rect.minX + tl, y: rect.minY + tl), radius: tl,
                    startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        path.closeSubpath()
        return path
    }
}

// MARK: - Markdown theme

extension Theme {
    /// Markdown theme tuned for the Claude — Editorial Warmth palette.
    /// Headings use the system serif; inline code uses warm gold; copper
    /// accents anchor heading + link colors.
    static var shiroTheme: Theme {
        Theme()
            .text { ForegroundColor(.vText) }
            .code { FontFamilyVariant(.monospaced); ForegroundColor(.vActive) }
            .strong { FontWeight(.semibold) }
            .emphasis { FontStyle(.italic) }
            .link { ForegroundColor(.vAccent); UnderlineStyle(.single) }
            .heading1 { cfg in
                cfg.label.markdownTextStyle {
                    FontFamily(.system(.serif))
                    FontWeight(.semibold)
                    FontSize(18)
                    ForegroundColor(.vText)
                }
            }
            .heading2 { cfg in
                cfg.label.markdownTextStyle {
                    FontFamily(.system(.serif))
                    FontWeight(.semibold)
                    FontSize(16)
                    ForegroundColor(.vText)
                }
            }
            .heading3 { cfg in
                cfg.label.markdownTextStyle {
                    FontWeight(.semibold)
                    ForegroundColor(.vAccent)
                }
            }
            .blockquote { cfg in
                cfg.label
                    .padding(.leading, 12)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(Color.vAccent.opacity(0.6)).frame(width: 2)
                    }
                    .markdownTextStyle { ForegroundColor(.vMuted); FontStyle(.italic) }
            }
    }
}
