/*
 AESTHETIC: Void Interface — Full Agentic Workspace
 ───────────────────────────────────────────────────
 Background: #07090F  (deep space, midnight-navy undertone)
 Sidebar:    #0B0D15  (slightly warmer dark)
 Surface:    #0F1218  (cards, message backgrounds)
 Elevated:   #151A26  (hover, focus, panels)
 Border:     #1D2235
 Accent:     #6C63FF  (indigo-violet — AI-native)
 Active:     #10D9A4  (teal-emerald — running/success)
 Amber:      #F0A030  (thinking/warning)
 Red:        #EF4444  (error/stop)
 Text:       #DEE4FF  (cool near-white)
 Muted:      #5A6080
 DimMuted:   #363850

 Fonts:      JetBrains Mono — status, IDs, tool names
             SF Pro — chat prose, labels
*/

import SwiftUI
import MarkdownUI

// MARK: - Root window view

struct ShiroMainWindowView: View {
    @EnvironmentObject var appState: AppState

    // Active nav section
    @State private var activeSection: NavSection = .chat

    // Right panel visibility driven by user toggle + prefs
    @State private var rightPanelSection: RightPanelSection = .agents

    enum NavSection: String, CaseIterable {
        case chat      = "Chat"
        case routines  = "Routines"
        case browser   = "Browser"
        case settings  = "Settings"

        var icon: String {
            switch self {
            case .chat:     return "bubble.left.and.bubble.right"
            case .routines: return "clock.arrow.2.circlepath"
            case .browser:  return "eye"
            case .settings: return "gearshape"
            }
        }
    }

    enum RightPanelSection: String {
        case agents = "Agents"
        case tools  = "Tools"
    }

    var body: some View {
        HStack(spacing: 0) {
            // ── Left sidebar ──────────────────────────────────────────
            LeftSidebar(active: $activeSection, appState: appState)

            // ── Main content ──────────────────────────────────────────
            ZStack {
                Color(hex: "#07090F").ignoresSafeArea()

                switch activeSection {
                case .chat:
                    ChatWorkspace(
                        rightPanel: $rightPanelSection,
                        showAgents: appState.uiShowAgentsPanel,
                        showTools:  appState.uiShowToolFeed
                    )
                case .routines:
                    RoutinesView()
                case .browser:
                    BrowserControlView()
                case .settings:
                    WorkspaceSettingsView()
                }
            }
        }
        .background(Color(hex: "#07090F"))
        .task { await appState.refreshSubAgentSessions() }
        // Periodic sub-agent poll while window is open
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                await appState.refreshSubAgentSessions()
            }
        }
    }
}

// MARK: - Left Sidebar

private struct LeftSidebar: View {
    @Binding var active: ShiroMainWindowView.NavSection
    let appState: AppState

    private let sidebarWidth: CGFloat = 200

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Logo / title area
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(Color(hex: "#6C63FF").opacity(0.18)).frame(width: 30, height: 30)
                    Image(systemName: "waveform.circle.fill")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(Color(hex: "#6C63FF"))
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("SHIRO").font(.custom("JetBrains Mono", size: 13)).fontWeight(.bold)
                        .foregroundColor(Color(hex: "#DEE4FF"))
                        .tracking(2)
                    Text(routeLabel).font(.custom("JetBrains Mono", size: 9.5))
                        .foregroundColor(routeColor)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 20)
            .padding(.bottom, 16)

            // Status orb row
            statusRow
                .padding(.horizontal, 14)
                .padding(.bottom, 16)

            sidebarDivider

            // Navigation
            VStack(alignment: .leading, spacing: 2) {
                ForEach(ShiroMainWindowView.NavSection.allCases, id: \.self) { section in
                    SidebarNavItem(
                        icon:    section.icon,
                        label:   section.rawValue,
                        isActive: active == section,
                        badge:   badge(for: section)
                    ) { active = section }
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 12)

            sidebarDivider.padding(.top, 12)

            // Quick toggles
            VStack(alignment: .leading, spacing: 4) {
                Text("QUICK CONTROLS")
                    .font(.custom("JetBrains Mono", size: 9))
                    .foregroundColor(Color(hex: "#363850"))
                    .tracking(1.5)
                    .padding(.horizontal, 8)
                    .padding(.top, 12)
                    .padding(.bottom, 4)

                SidebarToggle(icon: "mic.fill", label: "Mic",
                              isOn: appState.isListening, activeColor: Color(hex: "#10D9A4")) {
                    // delegate to floating bar toggle logic
                }

                SidebarToggle(icon: "waveform.circle.fill", label: "Meeting Mode",
                              isOn: appState.isMeetingMode, activeColor: Color(hex: "#F0A030")) {
                    Task { @MainActor in appState.isMeetingMode.toggle() }
                }

                SidebarToggle(icon: "eye.fill", label: "Browser Control",
                              isOn: appState.browserControlEnabled, activeColor: Color(hex: "#6C63FF")) {
                    appState.setBrowserControl(!appState.browserControlEnabled)
                }

                SidebarToggle(icon: "rectangle.3.group", label: "Agents Panel",
                              isOn: appState.uiShowAgentsPanel, activeColor: Color(hex: "#6C63FF")) {
                    appState.uiShowAgentsPanel.toggle()
                    appState.saveUIPreferences()
                }

                SidebarToggle(icon: "list.bullet.rectangle", label: "Tool Feed",
                              isOn: appState.uiShowToolFeed, activeColor: Color(hex: "#6C63FF")) {
                    appState.uiShowToolFeed.toggle()
                    appState.saveUIPreferences()
                }
            }
            .padding(.horizontal, 8)

            Spacer()

            // Bottom: new chat + bridge status
            VStack(spacing: 8) {
                sidebarDivider

                Button {
                    appState.clearConversation()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "plus.circle")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(Color(hex: "#6C63FF"))
                        Text("New Chat")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(Color(hex: "#DEE4FF"))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Color(hex: "#6C63FF").opacity(0.1))
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8)

                bridgeStatusRow
                    .padding(.horizontal, 14)
                    .padding(.bottom, 16)
            }
        }
        .frame(width: sidebarWidth)
        .background(Color(hex: "#0B0D15"))
        .overlay(
            Rectangle()
                .fill(Color(hex: "#1D2235"))
                .frame(width: 1),
            alignment: .trailing
        )
    }

    private var sidebarDivider: some View {
        Rectangle()
            .fill(Color(hex: "#1D2235"))
            .frame(height: 1)
            .padding(.horizontal, 0)
    }

    private var routeLabel: String {
        switch appState.activeRouteMode {
        case .claudeCode: return "claude-cli"
        case .anthropic:  return "api"
        case .lmStudio:   return "local"
        }
    }

    private var routeColor: Color {
        switch appState.bridgeStatus {
        case .running:     return Color(hex: "#10D9A4")
        case .offline:     return Color(hex: "#EF4444")
        default:           return Color(hex: "#F0A030")
        }
    }

    private var statusRow: some View {
        HStack(spacing: 8) {
            ZStack {
                if appState.isProcessing {
                    Circle()
                        .fill(orbColor.opacity(0.25))
                        .frame(width: 22, height: 22)
                        .scaleEffect(1.4)
                        .animation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true),
                                   value: appState.isProcessing)
                }
                Circle().fill(orbColor).frame(width: 8, height: 8)
            }
            .frame(width: 22, height: 22)

            Text(appState.agentStatus.label)
                .font(.custom("JetBrains Mono", size: 10.5))
                .foregroundColor(Color(hex: "#5A6080"))
                .lineLimit(1)
        }
    }

    private var orbColor: Color {
        switch appState.agentStatus {
        case .idle:      return Color(hex: "#363850")
        case .listening: return Color(hex: "#10D9A4")
        case .thinking:  return Color(hex: "#6C63FF")
        case .acting:    return Color(hex: "#F0A030")
        case .speaking:  return Color(hex: "#10D9A4")
        case .error:     return Color(hex: "#EF4444")
        }
    }

    private var bridgeStatusRow: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(routeColor)
                .frame(width: 6, height: 6)
            Text(bridgeStatusLabel)
                .font(.custom("JetBrains Mono", size: 9.5))
                .foregroundColor(Color(hex: "#363850"))
                .lineLimit(1)
        }
    }

    private var bridgeStatusLabel: String {
        switch appState.bridgeStatus {
        case .starting:                    return "starting…"
        case .running(let label):          return label
        case .restarting(let a, let m):    return "restart \(a)/\(m)…"
        case .failingOver(let from, _):    return "failing over from \(from.rawValue)"
        case .offline(let reason):         return "offline: \(reason)"
        }
    }

    private func badge(for section: ShiroMainWindowView.NavSection) -> String? {
        switch section {
        case .chat:
            return appState.subAgentSessions.isEmpty ? nil : "\(appState.subAgentSessions.count)"
        default:
            return nil
        }
    }
}

// MARK: - Sidebar Nav Item

private struct SidebarNavItem: View {
    let icon:     String
    let label:    String
    let isActive: Bool
    let badge:    String?
    let action:   () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: isActive ? .semibold : .regular))
                    .foregroundColor(isActive ? Color(hex: "#6C63FF") : Color(hex: "#5A6080"))
                    .frame(width: 18)

                Text(label)
                    .font(.system(size: 13, weight: isActive ? .semibold : .regular))
                    .foregroundColor(isActive ? Color(hex: "#DEE4FF") : Color(hex: "#5A6080"))

                Spacer()

                if let badge {
                    Text(badge)
                        .font(.custom("JetBrains Mono", size: 9))
                        .foregroundColor(.black)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color(hex: "#6C63FF"))
                        .clipShape(Capsule())
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(isActive ? Color(hex: "#6C63FF").opacity(0.12) : Color.clear)
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Sidebar Toggle

private struct SidebarToggle: View {
    let icon:        String
    let label:       String
    let isOn:        Bool
    let activeColor: Color
    let action:      () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isOn ? activeColor : Color(hex: "#363850"))
                    .frame(width: 18)
                Text(label)
                    .font(.system(size: 12))
                    .foregroundColor(isOn ? Color(hex: "#DEE4FF") : Color(hex: "#363850"))
                Spacer()
                Circle()
                    .fill(isOn ? activeColor : Color(hex: "#1D2235"))
                    .frame(width: 7, height: 7)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Chat Workspace (3-column layout)

struct ChatWorkspace: View {
    @EnvironmentObject var appState: AppState
    @Binding var rightPanel:  ShiroMainWindowView.RightPanelSection
    let showAgents: Bool
    let showTools:  Bool

    @State private var inputText:    String = ""
    @State private var isTyping:     Bool   = false
    @State private var currentSendId: UUID? = nil
    @FocusState private var inputFocused: Bool

    private var messages: [DisplayMessage] { appState.conversationMessages }
    private var showRightPanel: Bool { showAgents || showTools }

    var body: some View {
        HStack(spacing: 0) {
            // ── Center: Chat ───────────────────────────────────────
            VStack(spacing: 0) {
                // Brain status bar
                brainStatusBar

                Divider().background(Color(hex: "#1D2235"))

                // Message thread
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            if messages.isEmpty {
                                emptyStateView
                            } else {
                                ForEach(messages) { msg in
                                    ChatMessageRow(message: msg)
                                        .id(msg.id)
                                }
                                if isTyping {
                                    TypingDots()
                                        .padding(.leading, 56)
                                        .padding(.top, 4)
                                        .id("typing-indicator")
                                }
                            }
                        }
                        .padding(.horizontal, 24)
                        .padding(.vertical, 20)
                    }
                    .onChange(of: messages.count) { _, _ in
                        withAnimation { proxy.scrollTo(messages.last?.id) }
                    }
                    .onChange(of: isTyping) { _, v in
                        if v { withAnimation { proxy.scrollTo("typing-indicator") } }
                    }
                }

                Divider().background(Color(hex: "#1D2235"))

                // Input bar
                chatInputBar
            }
            .background(Color(hex: "#07090F"))

            // ── Right panel (agents / tool feed) ──────────────────
            if showRightPanel {
                Divider().background(Color(hex: "#1D2235"))

                VStack(spacing: 0) {
                    // Panel picker
                    HStack(spacing: 0) {
                        panelPickerButton("Agents", section: .agents,
                                          icon: "cpu", available: showAgents)
                        panelPickerButton("Tool Feed", section: .tools,
                                          icon: "list.bullet.rectangle", available: showTools)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(hex: "#0B0D15"))

                    Divider().background(Color(hex: "#1D2235"))

                    switch rightPanel {
                    case .agents:
                        AgentsPanelView()
                    case .tools:
                        ToolFeedView()
                    }
                }
                .frame(width: 280)
                .background(Color(hex: "#0B0D15"))
            }
        }
    }

    // MARK: Brain status bar

    private var brainStatusBar: some View {
        HStack(spacing: 16) {
            // State
            HStack(spacing: 6) {
                Circle()
                    .fill(stateColor)
                    .frame(width: 7, height: 7)
                    .opacity(appState.isProcessing ? 1 : 0.5)
                    .scaleEffect(appState.isProcessing ? 1.2 : 1.0)
                    .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true),
                               value: appState.isProcessing)
                Text(appState.agentStatus.label)
                    .font(.custom("JetBrains Mono", size: 11))
                    .foregroundColor(Color(hex: "#5A6080"))
            }

            Spacer()

            // Active sub-agent count
            if !appState.subAgentSessions.isEmpty {
                HStack(spacing: 5) {
                    Image(systemName: "cpu")
                        .font(.system(size: 10))
                        .foregroundColor(Color(hex: "#6C63FF"))
                    Text("\(appState.subAgentSessions.count) agent\(appState.subAgentSessions.count == 1 ? "" : "s")")
                        .font(.custom("JetBrains Mono", size: 10.5))
                        .foregroundColor(Color(hex: "#6C63FF"))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color(hex: "#6C63FF").opacity(0.1))
                .clipShape(Capsule())
            }

            // Stop button
            if appState.isProcessing {
                Button {
                    appState.agentCoordinator?.bridge?.interrupt(sessionKey: "main")
                    appState.acpBridge?.interrupt(sessionKey: "main")
                    appState.isProcessing = false
                    appState.agentStatus  = .idle
                    isTyping              = false
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 11))
                        Text("Stop")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(Color(hex: "#EF4444"))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color(hex: "#EF4444").opacity(0.1))
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(Color(hex: "#0B0D15"))
    }

    private var stateColor: Color {
        switch appState.agentStatus {
        case .idle:      return Color(hex: "#363850")
        case .listening: return Color(hex: "#10D9A4")
        case .thinking:  return Color(hex: "#6C63FF")
        case .acting:    return Color(hex: "#F0A030")
        case .speaking:  return Color(hex: "#10D9A4")
        case .error:     return Color(hex: "#EF4444")
        }
    }

    // MARK: Empty state

    private var emptyStateView: some View {
        VStack(spacing: 24) {
            Spacer().frame(height: 60)
            ZStack {
                Circle()
                    .fill(Color(hex: "#6C63FF").opacity(0.08))
                    .frame(width: 80, height: 80)
                Image(systemName: "waveform.circle")
                    .font(.system(size: 36, weight: .light))
                    .foregroundColor(Color(hex: "#6C63FF").opacity(0.5))
            }
            VStack(spacing: 8) {
                Text("Shiro is ready")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(Color(hex: "#DEE4FF"))
                Text("Type a message or use a skill with /skill-name")
                    .font(.system(size: 13))
                    .foregroundColor(Color(hex: "#5A6080"))
            }
            // Quick actions
            HStack(spacing: 12) {
                quickActionChip(label: "Daily brief", icon: "sun.horizon") {
                    inputText = "/daily-brief"; sendMessage()
                }
                quickActionChip(label: "Search memory", icon: "magnifyingglass") {
                    inputText = "Search my memory for: "
                    inputFocused = true
                }
                quickActionChip(label: "Ingest files", icon: "tray.and.arrow.down") {
                    inputText = "/ingest ~/"; sendMessage()
                }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func quickActionChip(label: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                Text(label)
                    .font(.system(size: 12))
            }
            .foregroundColor(Color(hex: "#DEE4FF"))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color(hex: "#151A26"))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color(hex: "#1D2235"), lineWidth: 1)
            )
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }

    // MARK: Chat input bar

    private var chatInputBar: some View {
        HStack(alignment: .bottom, spacing: 12) {
            // Text editor for multi-line input
            ZStack(alignment: .topLeading) {
                if inputText.isEmpty {
                    Text(placeholder)
                        .font(.system(size: 13))
                        .foregroundColor(Color(hex: "#363850"))
                        .padding(.top, 12)
                        .padding(.leading, 14)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $inputText)
                    .font(.system(size: 13))
                    .foregroundColor(Color(hex: "#DEE4FF"))
                    .scrollContentBackground(.hidden)
                    .background(Color.clear)
                    .focused($inputFocused)
                    .frame(minHeight: 44, maxHeight: 160)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .onKeyPress(.return) {
                        if NSEvent.modifierFlags.contains(.shift) {
                            return .ignored  // shift+enter = newline
                        }
                        sendMessage()
                        return .handled
                    }
            }
            .background(Color(hex: "#0F1218"))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(
                        inputFocused ? Color(hex: "#6C63FF").opacity(0.5) : Color(hex: "#1D2235"),
                        lineWidth: 1
                    )
            )
            .cornerRadius(12)

            // Send / Stop
            VStack(spacing: 8) {
                if appState.isProcessing {
                    stopButton
                } else {
                    sendButton
                }
                // Mic
                Button { /* toggle listening */ } label: {
                    Image(systemName: appState.isListening ? "mic.fill" : "mic")
                        .font(.system(size: 14))
                        .foregroundColor(appState.isListening ? Color(hex: "#10D9A4") : Color(hex: "#5A6080"))
                        .frame(width: 36, height: 36)
                        .background(Color(hex: "#0F1218"))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(Color(hex: "#1D2235"), lineWidth: 1)
                        )
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Color(hex: "#0B0D15"))
    }

    private var sendButton: some View {
        Button { sendMessage() } label: {
            Image(systemName: inputText.isEmpty ? "arrow.up" : "arrow.up.circle.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(inputText.isEmpty ? Color(hex: "#363850") : Color(hex: "#6C63FF"))
                .frame(width: 36, height: 36)
                .background(inputText.isEmpty ? Color(hex: "#0F1218") : Color(hex: "#6C63FF").opacity(0.15))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(
                            inputText.isEmpty ? Color(hex: "#1D2235") : Color(hex: "#6C63FF").opacity(0.4),
                            lineWidth: 1
                        )
                )
                .cornerRadius(8)
        }
        .buttonStyle(.plain)
        .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .keyboardShortcut(.return, modifiers: [])
    }

    private var stopButton: some View {
        Button {
            appState.agentCoordinator?.bridge?.interrupt(sessionKey: "main")
            appState.acpBridge?.interrupt(sessionKey: "main")
            appState.isProcessing = false
            appState.agentStatus  = .idle
            isTyping              = false
        } label: {
            Image(systemName: "stop.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(Color(hex: "#EF4444"))
                .frame(width: 36, height: 36)
                .background(Color(hex: "#EF4444").opacity(0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color(hex: "#EF4444").opacity(0.4), lineWidth: 1)
                )
                .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }

    private var placeholder: String {
        switch appState.activeRouteMode {
        case .claudeCode: return "Message Shiro via Claude CLI…  (Return to send, Shift+Return for new line)"
        case .anthropic:  return "Message Shiro via API…  (Return to send)"
        case .lmStudio:
            return appState.lmStudioConnected
                ? "Message Shiro…  (Return to send)"
                : "⚠  LM Studio not connected — start LM Studio or switch route in Settings"
        }
    }

    // MARK: Right panel picker

    private func panelPickerButton(
        _ label: String,
        section: ShiroMainWindowView.RightPanelSection,
        icon: String,
        available: Bool
    ) -> some View {
        Button {
            guard available else { return }
            rightPanel = section
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                Text(label)
                    .font(.system(size: 11, weight: rightPanel == section ? .semibold : .regular))
            }
            .foregroundColor(
                !available ? Color(hex: "#363850") :
                rightPanel == section ? Color(hex: "#6C63FF") : Color(hex: "#5A6080")
            )
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(rightPanel == section ? Color(hex: "#6C63FF").opacity(0.1) : Color.clear)
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
        .disabled(!available)
    }

    // MARK: Send

    private func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let coordinator = appState.agentCoordinator else { return }
        inputText = ""

        var queryText             = text
        var systemPromptOverride: String? = nil

        if text.hasPrefix("/"),
           let registry = appState.skillsRegistry,
           let resolved = registry.resolve(input: text) {
            queryText            = resolved.prompt
            systemPromptOverride = resolved.skill.systemPrompt
            appState.conversationMessages.append(
                DisplayMessage(role: .user, content: text, badge: "[\(resolved.skill.name)]")
            )
        } else {
            appState.conversationMessages.append(DisplayMessage(role: .user, content: text))
        }

        appState.conversationMessages.append(DisplayMessage(role: .assistant, content: ""))
        isTyping              = true
        appState.isProcessing = true
        appState.agentStatus  = .thinking

        let reqId = UUID()
        currentSendId = reqId

        coordinator.onStreamingToken = { [weak appState] token in
            guard let appState,
                  appState.conversationMessages.last?.role == .assistant else { return }
            let idx = appState.conversationMessages.indices.last!
            appState.conversationMessages[idx].content += token
        }

        coordinator.onTurnComplete = { [weak appState] _ in
            Task { @MainActor in
                isTyping               = false
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
                isTyping              = false
                appState.isProcessing = false
                appState.agentStatus  = .error(error.localizedDescription)
                if appState.conversationMessages.last?.role == .assistant {
                    let idx = appState.conversationMessages.indices.last!
                    appState.conversationMessages[idx].content = "❌ \(error.localizedDescription)"
                }
            }
        }
    }
}

// MARK: - Chat Message Row (full window version)

private struct ChatMessageRow: View {
    let message: DisplayMessage

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            if message.role == .user {
                Spacer(minLength: 80)
                VStack(alignment: .trailing, spacing: 5) {
                    Text(message.content)
                        .font(.system(size: 13.5))
                        .foregroundColor(Color(hex: "#07090F"))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Color(hex: "#6C63FF"))
                        .cornerRadius(16)
                        .vCornerRadius(3, corners: .topRight)

                    if let badge = message.badge {
                        Text(badge)
                            .font(.custom("JetBrains Mono", size: 9.5))
                            .foregroundColor(Color(hex: "#6C63FF").opacity(0.7))
                    }
                }
            } else if message.role == .assistant {
                // Avatar
                ZStack {
                    Circle()
                        .fill(Color(hex: "#6C63FF").opacity(0.12))
                        .frame(width: 28, height: 28)
                    Image(systemName: "waveform.circle")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(Color(hex: "#6C63FF"))
                }
                .padding(.top, 2)

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Text("Shiro")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(Color(hex: "#6C63FF"))
                        Text(message.timestamp, style: .time)
                            .font(.system(size: 10))
                            .foregroundColor(Color(hex: "#363850"))
                    }

                    if message.content.isEmpty {
                        TypingDots()
                    } else {
                        Markdown(message.content)
                            .markdownTheme(.shiroTheme)
                            .font(.system(size: 13.5))
                            .foregroundColor(Color(hex: "#DEE4FF"))
                            .textSelection(.enabled)
                    }

                    // Tool calls
                    if !message.toolCalls.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(message.toolCalls) { call in
                                ToolCallRow(call: call)
                            }
                        }
                    }
                }
                Spacer(minLength: 80)
            }
        }
    }
}

// MARK: - Tool Call Row

private struct ToolCallRow: View {
    let call: ToolCallInfo

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: statusIcon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(statusColor)
                .frame(width: 16)

            Text(call.name)
                .font(.custom("JetBrains Mono", size: 11))
                .foregroundColor(Color(hex: "#DEE4FF"))

            if let output = call.output, !output.isEmpty {
                Text("→")
                    .font(.system(size: 10))
                    .foregroundColor(Color(hex: "#363850"))
                Text(output.prefix(80))
                    .font(.custom("JetBrains Mono", size: 10.5))
                    .foregroundColor(Color(hex: "#5A6080"))
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color(hex: "#0F1218"))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color(hex: "#1D2235"), lineWidth: 0.8)
        )
        .cornerRadius(6)
    }

    private var statusIcon: String {
        if call.isRunning { return "arrow.triangle.2.circlepath" }
        if call.isError   { return "xmark.circle.fill" }
        return "checkmark.circle.fill"
    }

    private var statusColor: Color {
        if call.isRunning { return Color(hex: "#F0A030") }
        if call.isError   { return Color(hex: "#EF4444") }
        return Color(hex: "#10D9A4")
    }
}

// MARK: - Agents Panel View

struct AgentsPanelView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("SUB-AGENTS")
                    .font(.custom("JetBrains Mono", size: 9.5))
                    .foregroundColor(Color(hex: "#363850"))
                    .tracking(1.5)
                Spacer()
                Text("✓ \(appState.subAgentCompletedCount)  ✗ \(appState.subAgentFailedCount)")
                    .font(.custom("JetBrains Mono", size: 9.5))
                    .foregroundColor(Color(hex: "#363850"))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            if appState.subAgentSessions.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "cpu")
                        .font(.system(size: 28))
                        .foregroundColor(Color(hex: "#363850"))
                    Text("No active sub-agents")
                        .font(.system(size: 12))
                        .foregroundColor(Color(hex: "#363850"))
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 8) {
                        ForEach(appState.subAgentSessions) { session in
                            AgentSessionCard(session: session)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct AgentSessionCard: View {
    let session: SubAgentDisplayInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                // Depth indicator
                ForEach(0..<min(session.depth, 4), id: \.self) { _ in
                    Rectangle()
                        .fill(Color(hex: "#6C63FF").opacity(0.4))
                        .frame(width: 2, height: 14)
                        .cornerRadius(1)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(session.id.prefix(16))
                        .font(.custom("JetBrains Mono", size: 10))
                        .foregroundColor(Color(hex: "#DEE4FF"))
                    if let taskId = session.taskId {
                        Text("task: \(taskId.prefix(12))")
                            .font(.custom("JetBrains Mono", size: 9.5))
                            .foregroundColor(Color(hex: "#5A6080"))
                    }
                }

                Spacer()

                // Running indicator
                Circle()
                    .fill(Color(hex: "#10D9A4"))
                    .frame(width: 6, height: 6)
                    .scaleEffect(1.2)
                    .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true),
                               value: true)
            }

            // Cost bar
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text("cost")
                        .font(.custom("JetBrains Mono", size: 9))
                        .foregroundColor(Color(hex: "#363850"))
                    Spacer()
                    Text(String(format: "$%.4f / $%.2f", session.costAccrued, session.costBudget))
                        .font(.custom("JetBrains Mono", size: 9))
                        .foregroundColor(Color(hex: "#5A6080"))
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2).fill(Color(hex: "#1D2235")).frame(height: 3)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color(hex: "#6C63FF"))
                            .frame(width: geo.size.width * CGFloat(min(session.costAccrued / max(session.costBudget, 0.001), 1)), height: 3)
                    }
                }
                .frame(height: 3)
            }
        }
        .padding(10)
        .background(Color(hex: "#0F1218"))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color(hex: "#1D2235"), lineWidth: 1)
        )
        .cornerRadius(8)
    }
}

// MARK: - Tool Feed View

struct ToolFeedView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("TOOL FEED")
                    .font(.custom("JetBrains Mono", size: 9.5))
                    .foregroundColor(Color(hex: "#363850"))
                    .tracking(1.5)
                Spacer()
                Button {
                    appState.toolActivityFeed.removeAll()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 10))
                        .foregroundColor(Color(hex: "#363850"))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            if appState.toolActivityFeed.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "list.bullet.rectangle")
                        .font(.system(size: 28))
                        .foregroundColor(Color(hex: "#363850"))
                    Text("No tool activity yet")
                        .font(.system(size: 12))
                        .foregroundColor(Color(hex: "#363850"))
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(appState.toolActivityFeed) { item in
                                ToolFeedRow(item: item)
                                    .id(item.id)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                    }
                    .onChange(of: appState.toolActivityFeed.count) { _, _ in
                        withAnimation { proxy.scrollTo(appState.toolActivityFeed.last?.id) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ToolFeedRow: View {
    let item: ToolActivityItem

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: statusIcon)
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(statusColor)
                .frame(width: 12)

            Text(item.toolName)
                .font(.custom("JetBrains Mono", size: 10.5))
                .foregroundColor(Color(hex: "#DEE4FF"))

            Spacer()

            Text(item.startedAt, style: .time)
                .font(.custom("JetBrains Mono", size: 9))
                .foregroundColor(Color(hex: "#363850"))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(item.isRunning ? Color(hex: "#0F1218") : Color.clear)
        .cornerRadius(5)
    }

    private var statusIcon: String {
        if item.isRunning { return "circle.fill" }
        if item.isError   { return "xmark.circle.fill" }
        return "checkmark.circle.fill"
    }

    private var statusColor: Color {
        if item.isRunning { return Color(hex: "#F0A030") }
        if item.isError   { return Color(hex: "#EF4444") }
        return Color(hex: "#10D9A4")
    }
}

// MARK: - Routines View

struct RoutinesView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Routines")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(Color(hex: "#DEE4FF"))
                    Text("Automated triggers — edit ~/.shiro/hooks.json to add new ones")
                        .font(.system(size: 12))
                        .foregroundColor(Color(hex: "#5A6080"))
                }
                Spacer()
                Button {
                    appState.hooksEngine?.load()
                } label: {
                    Label("Reload", systemImage: "arrow.clockwise")
                        .font(.system(size: 12))
                        .foregroundColor(Color(hex: "#6C63FF"))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)

            Divider().background(Color(hex: "#1D2235")).padding(.horizontal, 20)

            if let engine = appState.hooksEngine {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 10) {
                        ForEach(engine.hooks) { hook in
                            RoutineCard(hook: hook, engine: engine)
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.vertical, 20)
                }
            } else {
                Spacer()
                Text("HooksEngine unavailable").foregroundColor(Color(hex: "#5A6080")).frame(maxWidth: .infinity)
                Spacer()
            }
        }
        .background(Color(hex: "#07090F"))
    }
}

private struct RoutineCard: View {
    let hook:   HooksEngine.Hook
    let engine: HooksEngine

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            // Type icon
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(typeColor.opacity(0.1)).frame(width: 36, height: 36)
                Image(systemName: typeIcon).font(.system(size: 15)).foregroundColor(typeColor)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(hook.name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Color(hex: "#DEE4FF"))
                    Spacer()
                    typeBadge
                }
                if let desc = hook.description {
                    Text(desc).font(.system(size: 12)).foregroundColor(Color(hex: "#5A6080")).lineLimit(2)
                }
                HStack(spacing: 12) {
                    actionBadge
                    if let schedule = hook.schedule {
                        Label(schedule, systemImage: "clock").font(.custom("JetBrains Mono", size: 10))
                            .foregroundColor(Color(hex: "#363850"))
                    }
                    if let path = hook.path {
                        Label(path, systemImage: "folder").font(.custom("JetBrains Mono", size: 10))
                            .foregroundColor(Color(hex: "#363850")).lineLimit(1)
                    }
                }
            }

            // Enable toggle
            Toggle("", isOn: Binding(
                get: { hook.enabled },
                set: { engine.setEnabled(hook.name, enabled: $0) }
            ))
            .toggleStyle(.switch)
            .scaleEffect(0.85)
            .tint(Color(hex: "#6C63FF"))
        }
        .padding(16)
        .background(Color(hex: "#0F1218"))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(hook.enabled ? Color(hex: "#6C63FF").opacity(0.25) : Color(hex: "#1D2235"), lineWidth: 1)
        )
        .cornerRadius(12)
    }

    private var typeIcon: String {
        switch hook.type {
        case "app_launch": return "app.badge"
        case "file_watch": return "eye"
        case "schedule":   return "clock"
        default:           return "bolt"
        }
    }

    private var typeColor: Color {
        switch hook.type {
        case "app_launch": return Color(hex: "#10D9A4")
        case "file_watch": return Color(hex: "#6C63FF")
        case "schedule":   return Color(hex: "#F0A030")
        default:           return Color(hex: "#5A6080")
        }
    }

    private var typeBadge: some View {
        Text(hook.type.replacingOccurrences(of: "_", with: " ").uppercased())
            .font(.custom("JetBrains Mono", size: 8.5))
            .foregroundColor(typeColor)
            .tracking(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(typeColor.opacity(0.1))
            .cornerRadius(4)
    }

    private var actionBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: actionIcon)
                .font(.system(size: 9))
            Text(hook.action.type)
                .font(.custom("JetBrains Mono", size: 9.5))
        }
        .foregroundColor(Color(hex: "#5A6080"))
    }

    private var actionIcon: String {
        switch hook.action.type {
        case "skill":  return "wand.and.stars"
        case "query":  return "bubble.left"
        case "ingest": return "tray.and.arrow.down"
        default:       return "bolt"
        }
    }
}

// MARK: - Browser Control View

struct BrowserControlView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                // Header
                VStack(alignment: .leading, spacing: 6) {
                    Text("Browser Control")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(Color(hex: "#DEE4FF"))
                    Text("Enable continuous screen capture so Shiro can see what's on your screen and act accordingly.")
                        .font(.system(size: 13))
                        .foregroundColor(Color(hex: "#5A6080"))
                        .fixedSize(horizontal: false, vertical: true)
                }

                // Main toggle card
                HStack(spacing: 18) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(appState.browserControlEnabled
                                  ? Color(hex: "#6C63FF").opacity(0.15)
                                  : Color(hex: "#0F1218"))
                            .frame(width: 52, height: 52)
                        Image(systemName: appState.browserControlEnabled ? "eye.fill" : "eye")
                            .font(.system(size: 22))
                            .foregroundColor(appState.browserControlEnabled ? Color(hex: "#6C63FF") : Color(hex: "#5A6080"))
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Screen Awareness")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(Color(hex: "#DEE4FF"))
                        Text(appState.browserControlEnabled ? "Active — Shiro is watching your screen" : "Inactive — Shiro is working blind")
                            .font(.system(size: 12))
                            .foregroundColor(Color(hex: "#5A6080"))
                    }
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { appState.browserControlEnabled },
                        set: { appState.setBrowserControl($0) }
                    ))
                    .toggleStyle(.switch)
                    .tint(Color(hex: "#6C63FF"))
                }
                .padding(18)
                .background(Color(hex: "#0F1218"))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(
                            appState.browserControlEnabled ? Color(hex: "#6C63FF").opacity(0.35) : Color(hex: "#1D2235"),
                            lineWidth: 1
                        )
                )
                .cornerRadius(14)

                // Live summary
                if let summary = appState.latestScreenSummary {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("LAST CAPTURED")
                            .font(.custom("JetBrains Mono", size: 9.5))
                            .foregroundColor(Color(hex: "#363850"))
                            .tracking(1.5)
                        Text(summary)
                            .font(.custom("JetBrains Mono", size: 12))
                            .foregroundColor(Color(hex: "#DEE4FF"))
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(hex: "#0F1218"))
                            .cornerRadius(8)
                    }
                }

                // One-shot capture button
                Button {
                    Task {
                        let analysis = await appState.screenCapture?.analyzeNow()
                        if let a = analysis {
                            appState.latestScreenSummary = "[\(a.app)] \(a.windowTitle) — \(a.activity)"
                        }
                    }
                } label: {
                    Label("Capture now (one-shot)", systemImage: "camera")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(Color(hex: "#6C63FF"))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color(hex: "#6C63FF").opacity(0.1))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(Color(hex: "#6C63FF").opacity(0.3), lineWidth: 1)
                        )
                        .cornerRadius(10)
                }
                .buttonStyle(.plain)

                // Privacy note
                VStack(alignment: .leading, spacing: 6) {
                    Label("Privacy", systemImage: "lock.shield")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Color(hex: "#5A6080"))
                    Text("Screenshots are analyzed locally by your active LLM backend. Nothing is sent to external servers unless you are using the Anthropic API or Claude CLI route, in which case screenshot descriptions are included in the prompt.")
                        .font(.system(size: 11))
                        .foregroundColor(Color(hex: "#363850"))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(14)
                .background(Color(hex: "#0F1218"))
                .cornerRadius(10)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 28)
        }
        .background(Color(hex: "#07090F"))
    }
}

// MARK: - Workspace Settings View (embedded in main window tab)
// Uses the shared SettingsView defined in FloatingBarView.swift

private struct WorkspaceSettingsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Settings")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(Color(hex: "#DEE4FF"))
                Spacer()
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)
            .padding(.bottom, 8)

            // SettingsView is declared in FloatingBarView.swift (internal access)
            SettingsView()
                .environmentObject(appState)
        }
        .background(Color(hex: "#07090F"))
    }
}
