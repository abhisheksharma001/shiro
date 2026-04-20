/*
 AESTHETIC: Dark Terminal / Minimal Agency
 ─────────────────────────────────────────
 Background: #0D0D0D (near-black, not pure black)
 Accent:     #00FF85 (electric green — signals alive, active)
 Muted:      #3A3A3A (borders, inactive states)
 Text:       #E8E8E8 (warm white, easy on eyes)
 Error:      #FF4545 (red, sparing)

 Font:       JetBrains Mono for input + status (identity)
             SF Pro Display for labels + hints

 Layout:     Compact 60pt pill at top of screen
             Expands vertically when conversation is active
             Status dot pulses green when listening/thinking

 Signature:  Typing indicator: three green dots that bounce
             Status dot has a radial pulse ring when active
*/

import SwiftUI
import MarkdownUI

struct FloatingBarView: View {
    @EnvironmentObject var appState: AppState
    @State private var inputText: String = ""
    @State private var isExpanded: Bool = false
    @State private var messages: [DisplayMessage] = []
    @State private var isTyping: Bool = false
    /// Tracks the most recent send-request — stale streaming callbacks check
    /// this so concurrent sends can't interleave tokens into the wrong bubble.
    @State private var currentSendId: UUID? = nil
    @FocusState private var inputFocused: Bool

    // Colors
    private let bg = Color(hex: "#0D0D0D")
    private let accent = Color(hex: "#00FF85")
    private let muted = Color(hex: "#3A3A3A")
    private let textColor = Color(hex: "#E8E8E8")

    var body: some View {
        VStack(spacing: 8) {
            // ── Approval cards (above the bar) ─────────────────────
            if let gate = appState.consentGate, !gate.pendingApprovals.isEmpty {
                ApprovalQueueOverlay(gate: gate)
            }

            // ── Main floating bar ───────────────────────────────────
            ZStack {
                RoundedRectangle(cornerRadius: isExpanded ? 16 : 30)
                    .fill(bg)
                    .overlay(
                        RoundedRectangle(cornerRadius: isExpanded ? 16 : 30)
                            .strokeBorder(muted, lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.6), radius: 20, y: 4)

                VStack(spacing: 0) {
                    // ── Main Bar ─────────────────────────────────────
                    mainBar

                    // ── Meeting Mode ──────────────────────────────────
                    if appState.isMeetingMode {
                        Divider().background(muted).padding(.horizontal, 16)
                        MeetingModeView { _ in
                            withAnimation { isExpanded = false }
                        }
                        .transition(.asymmetric(
                            insertion: .move(edge: .top).combined(with: .opacity),
                            removal:   .move(edge: .top).combined(with: .opacity)
                        ))
                    }
                    // ── Expanded Chat Area ────────────────────────────
                    else if isExpanded {
                        Divider().background(muted).padding(.horizontal, 16)
                        chatArea
                            .transition(.asymmetric(
                                insertion: .move(edge: .top).combined(with: .opacity),
                                removal:   .move(edge: .top).combined(with: .opacity)
                            ))
                    }
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isExpanded)
        }
        .onAppear { checkLMStudio() }
    }

    // MARK: - Main Bar

    private var mainBar: some View {
        HStack(spacing: 12) {
            // Status indicator
            statusDot

            // Input
            ZStack(alignment: .leading) {
                if inputText.isEmpty {
                    Text(placeholderText)
                        .font(.custom("JetBrains Mono", size: 13))
                        .foregroundColor(Color(hex: "#5A5A5A"))
                }
                TextField("", text: $inputText)
                    .font(.custom("JetBrains Mono", size: 13))
                    .foregroundColor(textColor)
                    .textFieldStyle(.plain)
                    .focused($inputFocused)
                    .onSubmit { sendMessage() }
                    .onChange(of: inputFocused) { _, focused in
                        withAnimation { isExpanded = focused || !messages.isEmpty }
                    }
            }

            // Right controls
            HStack(spacing: 8) {
                // Meeting mode toggle
                meetingButton

                // Mic button (only in normal mode)
                if !appState.isMeetingMode {
                    micButton
                }

                // Send / Stop
                if appState.isProcessing {
                    stopButton
                } else if !inputText.isEmpty {
                    sendButton
                }
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 60)
    }

    // MARK: - Status Dot

    private var statusDot: some View {
        ZStack {
            Circle()
                .fill(statusColor.opacity(0.2))
                .frame(width: 24, height: 24)
                .scaleEffect(appState.isProcessing ? 1.4 : 1.0)
                .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true),
                           value: appState.isProcessing)

            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)
        }
        .frame(width: 24, height: 24)
        .help(appState.agentStatus.label)
    }

    private var statusColor: Color {
        switch appState.agentStatus {
        case .idle: return Color(hex: "#3A3A3A")
        case .listening: return accent
        case .thinking: return Color(hex: "#7B7BFF")
        case .acting: return Color(hex: "#FFB800")
        case .speaking: return accent
        case .error: return Color(hex: "#FF4545")
        }
    }

    // MARK: - Mic Button

    private var micButton: some View {
        Button {
            toggleListening()
        } label: {
            Image(systemName: appState.isListening ? "mic.fill" : "mic")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(appState.isListening ? accent : Color(hex: "#5A5A5A"))
                .frame(width: 28, height: 28)
                .background(
                    Circle().fill(appState.isListening ? accent.opacity(0.15) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .help(appState.isListening ? "Stop listening" : "Push to talk")
    }

    private var meetingButton: some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                appState.isMeetingMode.toggle()
                if appState.isMeetingMode { isExpanded = true }
            }
        } label: {
            Image(systemName: appState.isMeetingMode ? "waveform.circle.fill" : "waveform.circle")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(appState.isMeetingMode ? Color(hex: "#FFB800") : Color(hex: "#5A5A5A"))
                .frame(width: 28, height: 28)
                .background(
                    Circle().fill(appState.isMeetingMode ? Color(hex: "#FFB800").opacity(0.15) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .help(appState.isMeetingMode ? "Exit meeting mode" : "Start meeting mode")
    }

    private var sendButton: some View {
        Button { sendMessage() } label: {
            Image(systemName: "arrow.up.circle.fill")
                .font(.system(size: 22))
                .foregroundColor(accent)
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.return, modifiers: [])
    }

    private var stopButton: some View {
        Button {
            appState.acpBridge?.interrupt(sessionKey: "main")
            appState.agentCoordinator?.bridge?.interrupt(sessionKey: "main")
            appState.isProcessing = false
            appState.agentStatus = .idle
            isTyping = false
        } label: {
            Image(systemName: "stop.circle.fill")
                .font(.system(size: 22))
                .foregroundColor(Color(hex: "#FF4545"))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Chat Area

    private var chatArea: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(messages) { msg in
                            MessageBubble(message: msg, accent: accent, textColor: textColor)
                                .id(msg.id)
                        }
                        if isTyping {
                            typingIndicator
                        }
                    }
                    .padding(16)
                }
                .frame(maxHeight: 400)
                .onChange(of: messages.count) { _, _ in
                    withAnimation { proxy.scrollTo(messages.last?.id) }
                }
                .onChange(of: isTyping) { _, _ in
                    if isTyping { proxy.scrollTo("typing") }
                }
            }

            // Status line
            if appState.isProcessing {
                HStack(spacing: 6) {
                    Text(appState.agentStatus.label)
                        .font(.custom("JetBrains Mono", size: 11))
                        .foregroundColor(Color(hex: "#5A5A5A"))
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
        }
    }

    private var typingIndicator: some View {
        HStack(spacing: 4) {
            ForEach(0..<3) { i in
                Circle()
                    .fill(accent)
                    .frame(width: 5, height: 5)
                    .scaleEffect(isTyping ? 1.2 : 0.8)
                    .animation(
                        .easeInOut(duration: 0.4)
                            .repeatForever(autoreverses: true)
                            .delay(Double(i) * 0.12),
                        value: isTyping
                    )
            }
        }
        .padding(.vertical, 8)
        .id("typing")
    }

    // MARK: - Placeholder

    private var placeholderText: String {
        if !appState.lmStudioConnected { return "⚠ LM Studio not connected" }
        return "Ask Shiro anything… (⌘.)"
    }

    // MARK: - Actions

    private func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let coordinator = appState.agentCoordinator else { return }
        inputText = ""

        // ── Slash command / skill routing ─────────────────────────────────
        var queryText = text
        var systemPromptOverride: String? = nil

        if text.hasPrefix("/"),
           let registry = appState.skillsRegistry,
           let resolved = registry.resolve(input: text) {
            // Matched a skill: display the slash command as typed,
            // but send the filled prompt with the skill's system prompt.
            queryText = resolved.prompt
            systemPromptOverride = resolved.skill.systemPrompt
            // Show a badge so the user knows which skill ran
            messages.append(DisplayMessage(
                role: .user,
                content: text,
                badge: "[\(resolved.skill.name)]"
            ))
        } else {
            messages.append(DisplayMessage(role: .user, content: text))
        }

        // ── Streaming assistant bubble ─────────────────────────────────────
        messages.append(DisplayMessage(role: .assistant, content: ""))
        isTyping = true
        appState.isProcessing = true
        appState.agentStatus = .thinking

        // Per-request id so a second send() won't capture tokens from the
        // previous in-flight request.
        let requestId = UUID()
        currentSendId = requestId

        // ── Set callbacks BEFORE send() — otherwise the bridge's first
        //    text_delta can arrive before we subscribe and tokens are lost.
        coordinator.onStreamingToken = { [self] token in
            guard currentSendId == requestId else { return }
            guard let last = messages.indices.last else { return }
            let updated = DisplayMessage(role: .assistant,
                                          content: messages[last].content + token)
            messages[last] = updated
        }
        coordinator.onTurnComplete = { [self] _ in
            guard currentSendId == requestId else { return }
            isTyping = false
            appState.isProcessing = false
            appState.agentStatus = .idle
            coordinator.onStreamingToken = nil
            coordinator.onTurnComplete = nil
        }

        Task {
            do {
                _ = try await coordinator.send(
                    query: queryText,
                    systemPrompt: systemPromptOverride
                )
            } catch {
                await MainActor.run {
                    isTyping = false
                    if let last = messages.indices.last {
                        messages[last] = DisplayMessage(role: .assistant,
                                                         content: "❌ \(error.localizedDescription)")
                    }
                    appState.isProcessing = false
                    appState.agentStatus = .error(error.localizedDescription)
                }
            }
        }
    }

    private func toggleListening() {
        if appState.isListening {
            appState.isListening = false
            appState.agentStatus = .idle
            // Stop STT
            _ = appState.stt?.stopMeetingMode()
        } else {
            appState.isListening = true
            appState.agentStatus = .listening
            // Start STT → when segment arrives, send as message
            appState.stt?.onSegment = { [weak appState] segment in
                guard segment.isFinal else { return }
                Task { @MainActor in
                    // Auto-send transcribed speech as query
                    // Small debounce: only send if silence follows
                    appState?.currentTranscript = segment.text
                }
            }
            appState.stt?.startMeetingMode()
        }
    }

    private func checkLMStudio() {
        Task {
            let connected = await appState.lmStudio?.healthCheck() ?? false
            await MainActor.run { appState.lmStudioConnected = connected }
        }
    }
}

// MARK: - Message Bubble

struct MessageBubble: View {
    let message: DisplayMessage
    let accent: Color
    let textColor: Color

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if message.role == .user {
                Spacer(minLength: 60)
                VStack(alignment: .trailing, spacing: 3) {
                    Text(message.content)
                        .font(.custom("JetBrains Mono", size: 12))
                        .foregroundColor(Color(hex: "#0D0D0D"))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(accent)
                        .cornerRadius(12)
                        .cornerRadius(3, corners: .topRight)
                    if let badge = message.badge {
                        Text(badge)
                            .font(.custom("JetBrains Mono", size: 9))
                            .foregroundColor(accent.opacity(0.7))
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Circle().fill(Color(hex: "#7B7BFF")).frame(width: 6, height: 6)
                        Text("shiro").font(.system(size: 9, weight: .bold)).foregroundColor(Color(hex: "#7B7BFF"))
                    }
                    Markdown(message.content)
                        .markdownTheme(.shiro(textColor: textColor))
                        .font(.system(size: 12))
                        .foregroundColor(textColor)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(hex: "#1A1A1A"))
                .cornerRadius(12)
                .cornerRadius(3, corners: .topLeft)
                Spacer(minLength: 60)
            }
        }
    }
}

// MARK: - Supporting Types

struct DisplayMessage: Identifiable {
    let id = UUID()
    let role: MessageRole
    let content: String
    let timestamp = Date()
    /// Optional label shown below the bubble (e.g. "[research]" for skill invocations).
    var badge: String? = nil

    enum MessageRole { case user, assistant }
}

// MARK: - Settings View

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
        }
        .frame(width: 560, height: 480)
        .padding(8)
        .environmentObject(appState)
    }
}

// MARK: Route Mode tab — pick LLM backend (LM Studio / Anthropic API / Claude CLI)

private struct RouteModeTab: View {
    @EnvironmentObject var appState: AppState
    @State private var selected: Config.RouteMode = Config.routeMode
    @State private var allowedDirs: [String] = Config.allowedDirectories
    @State private var newDir: String = ""
    @State private var switching = false
    @State private var statusMsg: String?

    var body: some View {
        Form {
            Section("Active backend") {
                LabeledContent("Current", value: appState.activeRouteMode.displayName)
                LabeledContent("Running", value: (appState.bridgeRouter?.isRunning ?? false) ? "✅ Yes" : "❌ No")
            }

            Section("Switch backend") {
                Picker("Mode", selection: $selected) {
                    ForEach(Config.RouteMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)

                Text(hint(for: selected))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if selected == .claudeCode {
                    LabeledContent("Claude CLI",
                                   value: Config.claudeCodeCLIAvailable ? "✅ Found" : "❌ Not installed")
                        .font(.system(size: 11))
                }

                HStack {
                    Spacer()
                    if let msg = statusMsg {
                        Text(msg).font(.system(size: 11)).foregroundColor(.green)
                    }
                    Button(switching ? "Switching…" : "Apply") {
                        Task { await apply() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(switching || selected == appState.activeRouteMode)
                }
            }

            Section("PC access — directories the agent can touch") {
                Text("Applies to Claude CLI route. Each entry is passed as --add-dir.")
                    .font(.system(size: 11)).foregroundColor(.secondary)

                ForEach(allowedDirs.indices, id: \.self) { i in
                    HStack {
                        Text(allowedDirs[i]).font(.system(size: 12, design: .monospaced)).lineLimit(1)
                        Spacer()
                        Button(role: .destructive) {
                            allowedDirs.remove(at: i)
                            Config.setAllowedDirectories(allowedDirs)
                        } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.plain)
                    }
                }

                HStack {
                    TextField("/absolute/path or ~/Folder", text: $newDir)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                    Button("Add") {
                        let expanded = (newDir as NSString).expandingTildeInPath
                        guard !expanded.isEmpty,
                              !allowedDirs.contains(expanded) else { return }
                        allowedDirs.append(expanded)
                        Config.setAllowedDirectories(allowedDirs)
                        newDir = ""
                    }
                }

                Button("Grant full ~/ access") {
                    allowedDirs = [NSHomeDirectory()]
                    Config.setAllowedDirectories(allowedDirs)
                }
                .font(.system(size: 11))
            }
        }
        .formStyle(.grouped)
    }

    private func hint(for mode: Config.RouteMode) -> String {
        switch mode {
        case .lmStudio:
            return "Fully local. Free. Uses LM Studio + Shiro's custom tools (SQL, memory, KG, skills)."
        case .anthropic:
            return "Bring-your-own API key (sk-ant-…). Real Claude, billed per-token via your Anthropic account. Full Shiro tools."
        case .claudeCode:
            return "Uses your Claude Pro/Max subscription quota via the local `claude` CLI. Built-in CLI tools only (no Shiro memory/KG yet). Requires `claude` installed + logged in."
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
                    LabeledContent("Claude CLI", value: Config.claudeCodeCLIAvailable ? "✅ Found" : "❌ Missing")
                    LabeledContent("PC access", value: Config.allowedDirectories.first ?? "~")
                case .anthropic:
                    LabeledContent("API key", value: Config.anthropicEnabled ? "✅ Set" : "❌ Missing (add in API Keys tab)")
                case .lmStudio:
                    LabeledContent("LM Studio", value: appState.lmStudioConnected ? "✅ Connected" : "❌ Disconnected — start LM Studio")
                    LabeledContent("Brain model",     value: Config.brainModel)
                    LabeledContent("Fast model",      value: Config.fastModel)
                    LabeledContent("Vision model",    value: Config.visionModel)
                    LabeledContent("Embed model",     value: Config.embeddingModel)
                }
            }
            Section("Services") {
                LabeledContent("Deepgram STT",  value: Config.deepgramEnabled  ? "✅ Active" : "⚪ Whisper fallback")
                LabeledContent("Telegram",      value: Config.telegramEnabled  ? "✅ Active" : "⚪ Off — add key in API Keys tab")
                LabeledContent("Memory Store",  value: appState.memoryStore   != nil ? "✅ Ready" : "⚪ Unavailable")
                LabeledContent("Skills",        value: "\(appState.skillsRegistry?.skills.count ?? 0) loaded — ~/.shiro/skills/")
                LabeledContent("Hooks",         value: "\(appState.hooksEngine?.hooks.filter(\.enabled).count ?? 0) active — ~/.shiro/hooks.json")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: API Keys tab

private struct APIKeysTab: View {
    // Bound to keychain — initialise from current values
    @State private var anthropicKey:   String = KeychainHelper.get(.anthropicAPIKey)   ?? ""
    @State private var deepgramKey:    String = KeychainHelper.get(.deepgramAPIKey)    ?? ""
    @State private var telegramToken:  String = KeychainHelper.get(.telegramBotToken)  ?? ""
    @State private var telegramChatId: String = KeychainHelper.get(.telegramChatId)    ?? ""
    @State private var openAIKey:      String = KeychainHelper.get(.openAIAPIKey)      ?? ""
    @State private var openAIBase:     String = KeychainHelper.get(.openAIBaseURL)     ?? ""
    @State private var saved = false

    var body: some View {
        Form {
            Section {
                Text("All keys are stored in your macOS Keychain — never in plain text or env vars.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            Section("Anthropic (BYOK — real Claude models)") {
                SecureTextField("sk-ant-…", text: $anthropicKey)
                if !anthropicKey.isEmpty {
                    Text(anthropicKey.hasPrefix("sk-ant-") ? "✅ Valid format" : "⚠️ Should start with sk-ant-")
                        .font(.system(size: 11))
                        .foregroundColor(anthropicKey.hasPrefix("sk-ant-") ? .green : .orange)
                }
                Text("When set, Shiro uses real Claude (Sonnet/Opus/Haiku) instead of LM Studio.")
                    .font(.system(size: 11)).foregroundColor(.secondary)
            }

            Section("Deepgram STT (real-time transcription)") {
                SecureTextField("Deepgram API key…", text: $deepgramKey)
                Text("Without this, Shiro falls back to LM Studio Whisper (slower, offline).")
                    .font(.system(size: 11)).foregroundColor(.secondary)
            }

            Section("Telegram (remote approval relay)") {
                SecureTextField("Bot token from @BotFather…", text: $telegramToken)
                TextField("Your chat ID from @userinfobot…", text: $telegramChatId)
                    .textFieldStyle(.roundedBorder)
                Text("Lets you approve/deny high-risk tools from your phone.")
                    .font(.system(size: 11)).foregroundColor(.secondary)
            }

            Section("OpenAI-compatible (any local or cloud endpoint)") {
                SecureTextField("API key (or 'local' for no auth)…", text: $openAIKey)
                TextField("Base URL (e.g. http://localhost:1234/v1)…", text: $openAIBase)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Spacer()
                if saved {
                    Label("Saved!", systemImage: "checkmark.circle.fill")
                        .foregroundColor(.green).font(.system(size: 12))
                }
                Button("Save to Keychain") { saveAll() }
                    .buttonStyle(.borderedProminent)
            }
            .padding(.top, 4)
        }
        .formStyle(.grouped)
    }

    private func saveAll() {
        KeychainHelper.set(anthropicKey,   for: .anthropicAPIKey)
        KeychainHelper.set(deepgramKey,    for: .deepgramAPIKey)
        KeychainHelper.set(telegramToken,  for: .telegramBotToken)
        KeychainHelper.set(telegramChatId, for: .telegramChatId)
        KeychainHelper.set(openAIKey,      for: .openAIAPIKey)
        KeychainHelper.set(openAIBase,     for: .openAIBaseURL)
        saved = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { saved = false }
    }
}

// Secure text field wrapper
private struct SecureTextField: View {
    let placeholder: String
    @Binding var text: String
    @State private var isVisible = false

    init(_ placeholder: String, text: Binding<String>) {
        self.placeholder = placeholder
        self._text = text
    }

    var body: some View {
        HStack {
            if isVisible {
                TextField(placeholder, text: $text).textFieldStyle(.roundedBorder)
            } else {
                SecureField(placeholder, text: $text).textFieldStyle(.roundedBorder)
            }
            Button { isVisible.toggle() } label: {
                Image(systemName: isVisible ? "eye.slash" : "eye")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
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
                            Circle()
                                .fill(server.enabled ? Color(hex: "#00FF85") : Color(hex: "#3A3A3A"))
                                .frame(width: 7, height: 7)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(server.name)
                                    .font(.custom("JetBrains Mono", size: 12))
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

// MARK: - Color + Corner helpers

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int = UInt64()
        Scanner(string: hex).scanHexInt64(&int)
        let r = Double((int >> 16) & 0xFF) / 255
        let g = Double((int >> 8) & 0xFF) / 255
        let b = Double(int & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}

extension View {
    func cornerRadius(_ radius: CGFloat, corners: RectCorner) -> some View {
        clipShape(RoundedCornerShape(radius: radius, corners: corners))
    }
}

struct RectCorner: OptionSet {
    let rawValue: Int
    static let topLeft = RectCorner(rawValue: 1 << 0)
    static let topRight = RectCorner(rawValue: 1 << 1)
    static let bottomLeft = RectCorner(rawValue: 1 << 2)
    static let bottomRight = RectCorner(rawValue: 1 << 3)
    static let all: RectCorner = [.topLeft, .topRight, .bottomLeft, .bottomRight]
}

struct RoundedCornerShape: Shape {
    var radius: CGFloat
    var corners: RectCorner
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let tl: CGFloat = corners.contains(.topLeft) ? radius : 0
        let tr: CGFloat = corners.contains(.topRight) ? radius : 0
        let bl: CGFloat = corners.contains(.bottomLeft) ? radius : 0
        let br: CGFloat = corners.contains(.bottomRight) ? radius : 0
        path.move(to: CGPoint(x: rect.minX + tl, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - tr, y: rect.minY))
        path.addArc(center: CGPoint(x: rect.maxX - tr, y: rect.minY + tr), radius: tr, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - br))
        path.addArc(center: CGPoint(x: rect.maxX - br, y: rect.maxY - br), radius: br, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        path.addLine(to: CGPoint(x: rect.minX + bl, y: rect.maxY))
        path.addArc(center: CGPoint(x: rect.minX + bl, y: rect.maxY - bl), radius: bl, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + tl))
        path.addArc(center: CGPoint(x: rect.minX + tl, y: rect.minY + tl), radius: tl, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        path.closeSubpath()
        return path
    }
}

// Markdown theme
extension Theme {
    static func shiro(textColor: Color) -> Theme {
        Theme()
            .text { ForegroundColor(textColor) }
            .code { FontFamilyVariant(.monospaced); ForegroundColor(Color(hex: "#00FF85")) }
            .strong { FontWeight(.bold) }
            .heading1 { configuration in
                configuration.label
                    .markdownTextStyle { ForegroundColor(Color(hex: "#7B7BFF")); FontWeight(.bold) }
            }
            .heading2 { configuration in
                configuration.label
                    .markdownTextStyle { ForegroundColor(Color(hex: "#7B7BFF")); FontWeight(.semibold) }
            }
    }
}
