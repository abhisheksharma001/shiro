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
                Color.vBg.ignoresSafeArea()

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
        .background(Color.vBg)
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
            // Wordmark — editorial serif, copper accent dot
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Circle()
                    .fill(Color.vAccent)
                    .frame(width: 8, height: 8)
                    .offset(y: -2)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Shiro")
                        .font(ShiroFont.serif(size: 22, weight: .semibold))
                        .foregroundColor(Color.vText)
                    Text(routeLabel.uppercased())
                        .font(ShiroFont.mono(size: 9))
                        .tracking(1.4)
                        .foregroundColor(routeColor)
                }
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.top, 22)
            .padding(.bottom, 18)

            // Status orb row
            statusRow
                .padding(.horizontal, 16)
                .padding(.bottom, 18)

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
            .padding(.horizontal, 10)
            .padding(.top, 14)

            sidebarDivider.padding(.top, 14)

            // Quick toggles
            VStack(alignment: .leading, spacing: 4) {
                Text("CONTROLS")
                    .font(ShiroFont.mono(size: 9))
                    .foregroundColor(Color.vDim)
                    .tracking(1.6)
                    .padding(.horizontal, 10)
                    .padding(.top, 14)
                    .padding(.bottom, 6)

                SidebarToggle(icon: "mic.fill", label: "Mic",
                              isOn: appState.isListening, activeColor: Color.vActive) {
                    appState.toggleListening()
                }

                SidebarToggle(icon: "waveform.circle.fill", label: "Meeting Mode",
                              isOn: appState.isMeetingMode, activeColor: Color.vAmber) {
                    Task { @MainActor in appState.isMeetingMode.toggle() }
                }

                SidebarToggle(icon: "eye.fill", label: "Browser Control",
                              isOn: appState.browserControlEnabled, activeColor: Color.vAccent) {
                    appState.setBrowserControl(!appState.browserControlEnabled)
                }

                SidebarToggle(icon: "rectangle.3.group", label: "Agents Panel",
                              isOn: appState.uiShowAgentsPanel, activeColor: Color.vAccent) {
                    appState.uiShowAgentsPanel.toggle()
                    appState.saveUIPreferences()
                }

                SidebarToggle(icon: "list.bullet.rectangle", label: "Tool Feed",
                              isOn: appState.uiShowToolFeed, activeColor: Color.vAccent) {
                    appState.uiShowToolFeed.toggle()
                    appState.saveUIPreferences()
                }

                SidebarToggle(icon: "chart.line.uptrend.xyaxis", label: "Forecast Mode",
                              isOn: appState.forecastModeEnabled, activeColor: Color.vActive) {
                    appState.forecastModeEnabled.toggle()
                    appState.saveUIPreferences()
                }
            }
            .padding(.horizontal, 8)

            Spacer()

            // Bottom: new chat + bridge status
            VStack(spacing: 8) {
                sidebarDivider

                NewChatButton()
                    .padding(.horizontal, 8)

                bridgeStatusRow
                    .padding(.horizontal, 14)
                    .padding(.bottom, 16)
            }
        }
        .frame(width: sidebarWidth)
        .background(Color.vSidebar)
        .overlay(
            Rectangle()
                .fill(Color.vBorder)
                .frame(width: 1),
            alignment: .trailing
        )
    }

    private var sidebarDivider: some View {
        Rectangle()
            .fill(Color.vBorder)
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
        case .running:     return Color.vActive
        case .offline:     return Color.vRed
        default:           return Color.vAmber
        }
    }

    private var statusRow: some View {
        HStack(spacing: 9) {
            ZStack {
                if appState.isProcessing {
                    Circle()
                        .fill(orbColor.opacity(0.22))
                        .frame(width: 22, height: 22)
                        .scaleEffect(1.4)
                        .animation(.easeInOut(duration: 0.95).repeatForever(autoreverses: true),
                                   value: appState.isProcessing)
                }
                Circle().fill(orbColor).frame(width: 8, height: 8)
            }
            .frame(width: 22, height: 22)

            Text(appState.agentStatus.label)
                .font(ShiroFont.ui(size: 11, weight: .medium))
                .foregroundColor(Color.vMuted)
                .lineLimit(1)
        }
    }

    private var orbColor: Color {
        switch appState.agentStatus {
        case .idle:      return Color.vDim
        case .listening: return Color.vActive
        case .thinking:  return Color.vAccent
        case .acting:    return Color.vAmber
        case .speaking:  return Color.vActive
        case .error:     return Color.vRed
        }
    }

    private var bridgeStatusRow: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(routeColor)
                .frame(width: 6, height: 6)
            Text(bridgeStatusLabel)
                .font(ShiroFont.mono(size: 9.5))
                .foregroundColor(Color.vDim)
                .lineLimit(1)
                .truncationMode(.tail)
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

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: isActive ? .semibold : .regular))
                    .foregroundColor(isActive ? Color.vAccent : Color.vMuted)
                    .frame(width: 18)

                Text(label)
                    .font(ShiroFont.ui(size: 13, weight: isActive ? .semibold : .regular))
                    .foregroundColor(isActive ? Color.vText : Color.vMuted)

                Spacer()

                if let badge {
                    Text(badge)
                        .font(ShiroFont.mono(size: 9, weight: .semibold))
                        .foregroundColor(Color(hex: "#1A1916"))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.vAccent)
                        .clipShape(Capsule())
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .background(
                ZStack {
                    if isActive {
                        Color.vAccent.opacity(0.10)
                    } else if hovering {
                        Color.vElev.opacity(0.6)
                    }
                }
            )
            .overlay(alignment: .leading) {
                if isActive {
                    Rectangle().fill(Color.vAccent).frame(width: 2)
                }
            }
            .cornerRadius(7)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

// MARK: - Sidebar Toggle

private struct SidebarToggle: View {
    let icon:        String
    let label:       String
    let isOn:        Bool
    let activeColor: Color
    let action:      () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isOn ? activeColor : Color.vDim)
                    .frame(width: 18)
                Text(label)
                    .font(ShiroFont.ui(size: 12, weight: isOn ? .medium : .regular))
                    .foregroundColor(isOn ? Color.vText : Color.vMuted)
                Spacer()
                // Pill switch — softer than a single dot
                Capsule()
                    .fill(isOn ? activeColor.opacity(0.85) : Color.vBorder)
                    .frame(width: 22, height: 12)
                    .overlay(alignment: isOn ? .trailing : .leading) {
                        Circle()
                            .fill(Color.vText)
                            .frame(width: 8, height: 8)
                            .padding(.horizontal, 2)
                    }
                    .animation(.spring(response: 0.25, dampingFraction: 0.85), value: isOn)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(hovering ? Color.vElev.opacity(0.5) : Color.clear)
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

// MARK: - Chip Button (warm, hover-aware)

private struct ChipButton: View {
    let label: String
    let icon: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(hovering ? Color.vAccent : Color.vMuted)
                Text(label)
                    .font(ShiroFont.ui(size: 12.5, weight: .medium))
                    .foregroundColor(Color.vText)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(hovering ? Color.vElev : Color.vSurface)
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(hovering ? Color.vAccent.opacity(0.45) : Color.vBorder, lineWidth: 0.8)
            )
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.14), value: hovering)
    }
}

// MARK: - New Chat Button (with brief "cleared" confirmation)

private struct NewChatButton: View {
    @EnvironmentObject var appState: AppState
    @State private var justCleared = false

    var body: some View {
        Button(action: tap) {
            HStack(spacing: 8) {
                Image(systemName: justCleared ? "checkmark.circle.fill" : "plus.circle")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(justCleared ? Color.vActive : Color.vAccent)
                Text(justCleared ? "Cleared" : "New Chat")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Color.vText)
                Spacer()
                Text("⌘N")
                    .font(.custom("JetBrains Mono", size: 9.5))
                    .foregroundColor(Color.vDim)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                (justCleared ? Color.vActive : Color.vAccent)
                    .opacity(justCleared ? 0.18 : 0.10)
            )
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
        .keyboardShortcut("n", modifiers: [.command])
        .help("Clear conversation and start fresh (⌘N)")
        .animation(.easeInOut(duration: 0.2), value: justCleared)
    }

    private func tap() {
        appState.clearConversation()
        justCleared = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 900_000_000)
            justCleared = false
        }
    }
}

// MARK: - Chat Workspace (3-column layout)

struct ChatWorkspace: View {
    @EnvironmentObject var appState: AppState
    @Binding var rightPanel:  ShiroMainWindowView.RightPanelSection
    let showAgents: Bool
    let showTools:  Bool

    @State private var inputText:     String = ""
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

                Divider().background(Color.vBorder)

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
                                if appState.isTypingMain {
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
                    .onChange(of: appState.isTypingMain) { _, v in
                        if v { withAnimation { proxy.scrollTo("typing-indicator") } }
                    }
                }

                Divider().background(Color.vBorder)

                // Input bar
                chatInputBar
            }
            .background(Color.vBg)

            // ── Right panel (agents / tool feed) ──────────────────
            if showRightPanel {
                Divider().background(Color.vBorder)

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
                    .background(Color.vSidebar)

                    Divider().background(Color.vBorder)

                    switch rightPanel {
                    case .agents:
                        AgentsPanelView()
                    case .tools:
                        ToolFeedView()
                    }
                }
                .frame(width: 280)
                .background(Color.vSidebar)
            }
        }
    }

    // MARK: Brain status bar

    private var brainStatusBar: some View {
        HStack(spacing: 14) {
            // State
            HStack(spacing: 7) {
                Circle()
                    .fill(stateColor)
                    .frame(width: 7, height: 7)
                    .opacity(appState.isProcessing ? 1 : 0.55)
                    .scaleEffect(appState.isProcessing ? 1.25 : 1.0)
                    .animation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true),
                               value: appState.isProcessing)
                Text(appState.agentStatus.label)
                    .font(ShiroFont.ui(size: 11.5, weight: .medium))
                    .foregroundColor(Color.vMuted)
            }

            // Forecast mode badge
            if appState.forecastModeEnabled {
                statusPill(icon: "chart.line.uptrend.xyaxis",
                           label: "FORECAST",
                           color: Color.vActive)
            }

            Spacer()

            // Active sub-agent count
            if !appState.subAgentSessions.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "cpu")
                        .font(.system(size: 10))
                        .foregroundColor(Color.vAccent)
                    Text("\(appState.subAgentSessions.count) agent\(appState.subAgentSessions.count == 1 ? "" : "s")")
                        .font(ShiroFont.mono(size: 10.5))
                        .foregroundColor(Color.vAccent)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background(Color.vAccent.opacity(0.12))
                .clipShape(Capsule())
            }

            // Stop button
            if appState.isProcessing {
                Button {
                    appState.agentCoordinator?.bridge?.interrupt(sessionKey: "main")
                    appState.acpBridge?.interrupt(sessionKey: "main")
                    appState.isProcessing  = false
                    appState.agentStatus   = .idle
                    appState.isTypingMain  = false
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 11))
                        Text("Stop")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(Color.vRed)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.vRed.opacity(0.1))
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(Color.vSidebar)
    }

    private var stateColor: Color {
        switch appState.agentStatus {
        case .idle:      return Color.vDim
        case .listening: return Color.vActive
        case .thinking:  return Color.vAccent
        case .acting:    return Color.vAmber
        case .speaking:  return Color.vActive
        case .error:     return Color.vRed
        }
    }

    /// Reusable mini status pill (icon + tracking-1 label, warm tinted bg).
    private func statusPill(icon: String, label: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .medium))
            Text(label)
                .font(ShiroFont.mono(size: 9, weight: .medium))
                .tracking(1.1)
        }
        .foregroundColor(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(color.opacity(0.12))
        .clipShape(Capsule())
    }

    // MARK: Empty state — editorial, generous whitespace

    private var emptyStateView: some View {
        VStack(spacing: 28) {
            Spacer().frame(height: 80)
            // No big circle/icon — just typography. Editorial restraint.
            VStack(alignment: .center, spacing: 14) {
                Text("Hi, I'm Shiro.")
                    .font(ShiroFont.serif(size: 36, weight: .regular))
                    .foregroundColor(Color.vText)
                Text("Ask me anything — or invoke a skill with /forecast, /research, /ingest.")
                    .font(ShiroFont.ui(size: 14))
                    .foregroundColor(Color.vMuted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)
            }
            // Quick actions
            HStack(spacing: 12) {
                if appState.forecastModeEnabled {
                    quickActionChip(label: "Forecast AAPL", icon: "chart.line.uptrend.xyaxis") {
                        inputText = "/forecast AAPL"; sendMessage()
                    }
                    quickActionChip(label: "Forecast BTC", icon: "bitcoinsign.circle") {
                        inputText = "/forecast BTC-USD"; sendMessage()
                    }
                } else {
                    quickActionChip(label: "Daily brief", icon: "sun.horizon") {
                        inputText = "/daily-brief"; sendMessage()
                    }
                    quickActionChip(label: "Research", icon: "sparkles.rectangle.stack") {
                        inputText = "/research "; inputFocused = true
                    }
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
        ChipButton(label: label, icon: icon, action: action)
    }

    // MARK: Chat input bar

    private var chatInputBar: some View {
        HStack(alignment: .bottom, spacing: 12) {
            // Text editor for multi-line input
            ZStack(alignment: .topLeading) {
                if inputText.isEmpty {
                    Text(placeholder)
                        .font(ShiroFont.ui(size: 13.5))
                        .foregroundColor(Color.vDim)
                        .padding(.top, 13)
                        .padding(.leading, 15)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $inputText)
                    .font(ShiroFont.ui(size: 13.5))
                    .foregroundColor(Color.vText)
                    .scrollContentBackground(.hidden)
                    .background(Color.clear)
                    .focused($inputFocused)
                    .frame(minHeight: 46, maxHeight: 160)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 9)
                    .onKeyPress(.return) {
                        if NSEvent.modifierFlags.contains(.shift) {
                            return .ignored  // shift+enter = newline
                        }
                        sendMessage()
                        return .handled
                    }
            }
            .background(Color.vSurface)
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(
                        inputFocused ? Color.vAccent.opacity(0.55) : Color.vBorder,
                        lineWidth: inputFocused ? 1.2 : 0.8
                    )
            )
            .shadow(color: inputFocused ? Color.vAccent.opacity(0.12) : .clear,
                    radius: 12, y: 2)
            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            .animation(.easeOut(duration: 0.18), value: inputFocused)

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
                        .foregroundColor(appState.isListening ? Color.vActive : Color.vMuted)
                        .frame(width: 36, height: 36)
                        .background(Color.vSurface)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(Color.vBorder, lineWidth: 1)
                        )
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Color.vSidebar)
    }

    private var sendButton: some View {
        Button { sendMessage() } label: {
            Image(systemName: inputText.isEmpty ? "arrow.up" : "arrow.up.circle.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(inputText.isEmpty ? Color.vDim : Color.vAccent)
                .frame(width: 36, height: 36)
                .background(inputText.isEmpty ? Color.vSurface : Color.vAccent.opacity(0.15))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(
                            inputText.isEmpty ? Color.vBorder : Color.vAccent.opacity(0.4),
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
            appState.isProcessing  = false
            appState.agentStatus   = .idle
            appState.isTypingMain  = false
        } label: {
            Image(systemName: "stop.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(Color.vRed)
                .frame(width: 36, height: 36)
                .background(Color.vRed.opacity(0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.vRed.opacity(0.4), lineWidth: 1)
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
                !available ? Color.vDim :
                rightPanel == section ? Color.vAccent : Color.vMuted
            )
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(rightPanel == section ? Color.vAccent.opacity(0.1) : Color.clear)
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
        appState.isTypingMain  = true
        appState.isProcessing  = true
        appState.agentStatus   = .thinking

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
                appState?.isTypingMain = false
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
                appState.isTypingMain  = false
                appState.isProcessing  = false
                appState.agentStatus   = .error(error.localizedDescription)
                appState.logError(source: "agent", message: error.localizedDescription)
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
                        .font(ShiroFont.ui(size: 13.5))
                        .foregroundColor(Color.vBg)
                        .padding(.horizontal, 15)
                        .padding(.vertical, 11)
                        .background(Color.vAccent)
                        .clipShape(
                            UnevenRoundedRectangle(
                                topLeadingRadius: 16, bottomLeadingRadius: 16,
                                bottomTrailingRadius: 16, topTrailingRadius: 4,
                                style: .continuous
                            )
                        )

                    if let badge = message.badge {
                        Text(badge)
                            .font(ShiroFont.mono(size: 9.5))
                            .foregroundColor(Color.vAccent.opacity(0.75))
                    }
                }
            } else if message.role == .assistant {
                // Avatar — serif "S" mark, warm copper
                ZStack {
                    Circle()
                        .fill(Color.vAccent.opacity(0.14))
                        .frame(width: 30, height: 30)
                    Text("S")
                        .font(ShiroFont.serif(size: 16, weight: .semibold))
                        .foregroundColor(Color.vAccent)
                }
                .padding(.top, 2)

                VStack(alignment: .leading, spacing: 9) {
                    HStack(spacing: 8) {
                        Text("Shiro")
                            .font(ShiroFont.serif(size: 13, weight: .semibold))
                            .foregroundColor(Color.vAccent)
                        Text(message.timestamp, style: .time)
                            .font(ShiroFont.mono(size: 9.5))
                            .foregroundColor(Color.vDim)
                    }

                    if message.content.isEmpty && message.imageBase64 == nil {
                        TypingDots()
                    } else {
                        if !message.content.isEmpty {
                            Markdown(message.content)
                                .markdownTheme(.shiroTheme)
                                .font(.system(size: 13.5))
                                .foregroundColor(Color.vText)
                                .textSelection(.enabled)
                        }
                        // Forecast / chart image
                        if let b64 = message.imageBase64,
                           let data = Data(base64Encoded: b64),
                           let nsImg = NSImage(data: data) {
                            Image(nsImage: nsImg)
                                .resizable()
                                .scaledToFit()
                                .frame(maxWidth: 520)
                                .cornerRadius(10)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10)
                                        .strokeBorder(Color.vBorder, lineWidth: 1)
                                )
                                .padding(.top, 4)
                        }
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
                .foregroundColor(Color.vText)

            if let output = call.output, !output.isEmpty {
                Text("→")
                    .font(.system(size: 10))
                    .foregroundColor(Color.vDim)
                Text(output.prefix(80))
                    .font(.custom("JetBrains Mono", size: 10.5))
                    .foregroundColor(Color.vMuted)
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.vSurface)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.vBorder, lineWidth: 0.8)
        )
        .cornerRadius(6)
    }

    private var statusIcon: String {
        if call.isRunning { return "arrow.triangle.2.circlepath" }
        if call.isError   { return "xmark.circle.fill" }
        return "checkmark.circle.fill"
    }

    private var statusColor: Color {
        if call.isRunning { return Color.vAmber }
        if call.isError   { return Color.vRed }
        return Color.vActive
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
                    .foregroundColor(Color.vDim)
                    .tracking(1.5)
                Spacer()
                Text("✓ \(appState.subAgentCompletedCount)  ✗ \(appState.subAgentFailedCount)")
                    .font(.custom("JetBrains Mono", size: 9.5))
                    .foregroundColor(Color.vDim)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            if appState.subAgentSessions.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "cpu")
                        .font(.system(size: 28))
                        .foregroundColor(Color.vDim)
                    Text("No active sub-agents")
                        .font(.system(size: 12))
                        .foregroundColor(Color.vDim)
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
                        .fill(Color.vAccent.opacity(0.4))
                        .frame(width: 2, height: 14)
                        .cornerRadius(1)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(session.id.prefix(16))
                        .font(.custom("JetBrains Mono", size: 10))
                        .foregroundColor(Color.vText)
                    if let taskId = session.taskId {
                        Text("task: \(taskId.prefix(12))")
                            .font(.custom("JetBrains Mono", size: 9.5))
                            .foregroundColor(Color.vMuted)
                    }
                }

                Spacer()

                // Running indicator
                Circle()
                    .fill(Color.vActive)
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
                        .foregroundColor(Color.vDim)
                    Spacer()
                    Text(String(format: "$%.4f / $%.2f", session.costAccrued, session.costBudget))
                        .font(.custom("JetBrains Mono", size: 9))
                        .foregroundColor(Color.vMuted)
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2).fill(Color.vBorder).frame(height: 3)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.vAccent)
                            .frame(width: geo.size.width * CGFloat(min(session.costAccrued / max(session.costBudget, 0.001), 1)), height: 3)
                    }
                }
                .frame(height: 3)
            }
        }
        .padding(10)
        .background(Color.vSurface)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.vBorder, lineWidth: 1)
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
                    .foregroundColor(Color.vDim)
                    .tracking(1.5)
                Spacer()
                Button {
                    appState.toolActivityFeed.removeAll()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 10))
                        .foregroundColor(Color.vDim)
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
                        .foregroundColor(Color.vDim)
                    Text("No tool activity yet")
                        .font(.system(size: 12))
                        .foregroundColor(Color.vDim)
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
                .foregroundColor(Color.vText)

            Spacer()

            Text(item.startedAt, style: .time)
                .font(.custom("JetBrains Mono", size: 9))
                .foregroundColor(Color.vDim)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(item.isRunning ? Color.vSurface : Color.clear)
        .cornerRadius(5)
    }

    private var statusIcon: String {
        if item.isRunning { return "circle.fill" }
        if item.isError   { return "xmark.circle.fill" }
        return "checkmark.circle.fill"
    }

    private var statusColor: Color {
        if item.isRunning { return Color.vAmber }
        if item.isError   { return Color.vRed }
        return Color.vActive
    }
}

// MARK: - Routines View

struct RoutinesView: View {
    @EnvironmentObject var appState: AppState
    @State private var showingNewRoutine = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Routines")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(Color.vText)
                    Text("Automated triggers — create via + or edit ~/.shiro/hooks.json")
                        .font(.system(size: 12))
                        .foregroundColor(Color.vMuted)
                }
                Spacer()
                Button {
                    appState.hooksEngine?.load()
                } label: {
                    Label("Reload", systemImage: "arrow.clockwise")
                        .font(.system(size: 12))
                        .foregroundColor(Color.vAccent)
                }
                .buttonStyle(.plain)

                Button {
                    showingNewRoutine = true
                } label: {
                    Label("New Routine", systemImage: "plus.circle.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Color.vAccent)
                }
                .buttonStyle(.plain)
                .padding(.leading, 12)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)

            Divider().background(Color.vBorder).padding(.horizontal, 20)

            if let engine = appState.hooksEngine {
                if engine.hooks.isEmpty {
                    VStack(spacing: 12) {
                        Spacer()
                        Image(systemName: "clock.arrow.2.circlepath")
                            .font(.system(size: 36))
                            .foregroundColor(Color.vDim)
                        Text("No routines yet")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(Color.vMuted)
                        Text("Tap + New Routine to create your first automated trigger")
                            .font(.system(size: 12))
                            .foregroundColor(Color.vDim)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVStack(spacing: 10) {
                            ForEach(engine.hooks) { hook in
                                RoutineCard(hook: hook, engine: engine)
                            }
                        }
                        .padding(.horizontal, 28)
                        .padding(.vertical, 20)
                    }
                }
            } else {
                Spacer()
                Text("HooksEngine unavailable").foregroundColor(Color.vMuted).frame(maxWidth: .infinity)
                Spacer()
            }
        }
        .background(Color.vBg)
        .sheet(isPresented: $showingNewRoutine) {
            if let engine = appState.hooksEngine {
                NewRoutineSheet(engine: engine, isPresented: $showingNewRoutine)
                    .environmentObject(appState)
            }
        }
    }
}

// MARK: - New Routine Sheet

private struct NewRoutineSheet: View {
    let engine:      HooksEngine
    @Binding var isPresented: Bool

    // Fields
    @State private var name:         String = ""
    @State private var hookType:     String = "schedule"
    @State private var path:         String = ""
    @State private var schedule:     String = "09:00"
    @State private var description:  String = ""
    @State private var actionType:   String = "query"
    @State private var actionQuery:  String = ""
    @State private var actionSkill:  String = ""
    @State private var actionPath:   String = ""
    @State private var actionCorpus: String = "docs"
    @State private var enabled:      Bool   = true
    @State private var errorMsg:     String? = nil

    private let hookTypes   = ["schedule", "file_watch", "app_launch"]
    private let actionTypes = ["query", "skill", "ingest"]

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("New Routine")
                    .font(ShiroFont.serif(size: 18, weight: .semibold))
                    .foregroundColor(Color.vText)
                Spacer()
                Button("Cancel") { isPresented = false }
                    .buttonStyle(.plain)
                    .foregroundColor(Color.vMuted)
                Button("Create") { create() }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.vAccent)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)
            .padding(.bottom, 20)

            Divider().background(Color.vBorder)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 22) {

                    // Basic info
                    group("Basics") {
                        field("Name", hint: "e.g. daily-brief") { TextField("", text: $name).textFieldStyle(.roundedBorder) }
                        field("Description (optional)") { TextField("", text: $description).textFieldStyle(.roundedBorder) }
                        Toggle("Enabled", isOn: $enabled).tint(Color.vAccent)
                    }

                    // Trigger
                    group("Trigger") {
                        Picker("Type", selection: $hookType) {
                            ForEach(hookTypes, id: \.self) { t in
                                Text(hookTypeLabel(t)).tag(t)
                            }
                        }
                        .pickerStyle(.radioGroup)

                        if hookType == "schedule" {
                            field("Schedule", hint: "HH:MM for daily (e.g. 09:00) or every:N for interval (e.g. every:30)") {
                                TextField("09:00", text: $schedule).textFieldStyle(.roundedBorder)
                            }
                        } else if hookType == "file_watch" {
                            field("Watch path", hint: "~/path/to/file or directory") {
                                TextField("~/Documents/notes.md", text: $path).textFieldStyle(.roundedBorder)
                            }
                        }
                    }

                    // Action
                    group("Action") {
                        Picker("Action type", selection: $actionType) {
                            ForEach(actionTypes, id: \.self) { t in
                                Text(actionTypeLabel(t)).tag(t)
                            }
                        }
                        .pickerStyle(.radioGroup)

                        switch actionType {
                        case "query":
                            field("Message to send", hint: "Text sent to Shiro as if you typed it") {
                                TextEditor(text: $actionQuery)
                                    .font(ShiroFont.ui(size: 13))
                                    .frame(minHeight: 72)
                                    .padding(6)
                                    .background(Color.vSurface)
                                    .cornerRadius(8)
                            }
                        case "skill":
                            field("Skill name", hint: "e.g. daily-brief") {
                                TextField("", text: $actionSkill).textFieldStyle(.roundedBorder)
                            }
                        case "ingest":
                            field("Path to ingest", hint: "~/path/to/file or directory") {
                                TextField("~/Projects", text: $actionPath).textFieldStyle(.roundedBorder)
                            }
                            field("Corpus tag", hint: "e.g. docs, code, notes") {
                                TextField("docs", text: $actionCorpus).textFieldStyle(.roundedBorder)
                            }
                        default:
                            EmptyView()
                        }
                    }

                    if let err = errorMsg {
                        HStack(spacing: 7) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(Color.vRed)
                                .font(.system(size: 12))
                            Text(err)
                                .font(.system(size: 12))
                                .foregroundColor(Color.vRed)
                        }
                        .padding(12)
                        .background(Color.vRed.opacity(0.08))
                        .cornerRadius(8)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
            }
        }
        .frame(width: 520, height: 640)
        .background(Color.vBg)
    }

    // MARK: Helpers

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title.uppercased())
                .font(ShiroFont.mono(size: 9.5))
                .foregroundColor(Color.vDim)
                .tracking(1.4)
            content()
        }
    }

    private func field<Content: View>(_ label: String, hint: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(ShiroFont.ui(size: 12, weight: .medium))
                .foregroundColor(Color.vMuted)
            content()
            if let hint {
                Text(hint)
                    .font(ShiroFont.ui(size: 10.5))
                    .foregroundColor(Color.vDim)
            }
        }
    }

    private func hookTypeLabel(_ t: String) -> String {
        switch t {
        case "schedule":   return "Schedule (time-based)"
        case "file_watch": return "File Watch (on file change)"
        case "app_launch": return "App Launch (once at startup)"
        default:           return t
        }
    }

    private func actionTypeLabel(_ t: String) -> String {
        switch t {
        case "query":  return "Send message (text query to Shiro)"
        case "skill":  return "Run skill (invoke a /skill by name)"
        case "ingest": return "Ingest path (add files to memory)"
        default:       return t
        }
    }

    private func create() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { errorMsg = "Name is required."; return }

        let action: HooksEngine.HookAction
        switch actionType {
        case "skill":
            let s = actionSkill.trimmingCharacters(in: .whitespaces)
            guard !s.isEmpty else { errorMsg = "Skill name is required."; return }
            action = HooksEngine.HookAction(type: "skill", skill: s, args: nil, query: nil, path: nil, corpus: nil)
        case "ingest":
            let p = actionPath.trimmingCharacters(in: .whitespaces)
            guard !p.isEmpty else { errorMsg = "Ingest path is required."; return }
            let c = actionCorpus.trimmingCharacters(in: .whitespaces)
            action = HooksEngine.HookAction(type: "ingest", skill: nil, args: nil, query: nil, path: p, corpus: c.isEmpty ? "docs" : c)
        default: // query
            let q = actionQuery.trimmingCharacters(in: .whitespaces)
            guard !q.isEmpty else { errorMsg = "Message text is required."; return }
            action = HooksEngine.HookAction(type: "query", skill: nil, args: nil, query: q, path: nil, corpus: nil)
        }

        let hook = HooksEngine.Hook(
            name:        trimmedName,
            type:        hookType,
            path:        hookType == "file_watch" ? (path.isEmpty ? nil : path) : nil,
            schedule:    hookType == "schedule"   ? (schedule.isEmpty ? "09:00" : schedule) : nil,
            action:      action,
            enabled:     enabled,
            description: description.isEmpty ? nil : description
        )

        if let err = engine.appendHook(hook) {
            errorMsg = err
        } else {
            isPresented = false
        }
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
                        .foregroundColor(Color.vText)
                    Spacer()
                    typeBadge
                }
                if let desc = hook.description {
                    Text(desc).font(.system(size: 12)).foregroundColor(Color.vMuted).lineLimit(2)
                }
                HStack(spacing: 12) {
                    actionBadge
                    if let schedule = hook.schedule {
                        Label(schedule, systemImage: "clock").font(.custom("JetBrains Mono", size: 10))
                            .foregroundColor(Color.vDim)
                    }
                    if let path = hook.path {
                        Label(path, systemImage: "folder").font(.custom("JetBrains Mono", size: 10))
                            .foregroundColor(Color.vDim).lineLimit(1)
                    }
                }
            }

            VStack(spacing: 6) {
                // Enable toggle
                Toggle("", isOn: Binding(
                    get: { hook.enabled },
                    set: { engine.setEnabled(hook.name, enabled: $0) }
                ))
                .toggleStyle(.switch)
                .scaleEffect(0.85)
                .tint(Color.vAccent)

                // Delete
                Button(role: .destructive) {
                    engine.deleteHook(named: hook.name)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundColor(Color.vRed.opacity(0.7))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .background(Color.vSurface)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(hook.enabled ? Color.vAccent.opacity(0.25) : Color.vBorder, lineWidth: 1)
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
        case "app_launch": return Color.vActive
        case "file_watch": return Color.vAccent
        case "schedule":   return Color.vAmber
        default:           return Color.vMuted
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
        .foregroundColor(Color.vMuted)
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
                        .foregroundColor(Color.vText)
                    Text("Enable continuous screen capture so Shiro can see what's on your screen and act accordingly.")
                        .font(.system(size: 13))
                        .foregroundColor(Color.vMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // Main toggle card
                HStack(spacing: 18) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(appState.browserControlEnabled
                                  ? Color.vAccent.opacity(0.15)
                                  : Color.vSurface)
                            .frame(width: 52, height: 52)
                        Image(systemName: appState.browserControlEnabled ? "eye.fill" : "eye")
                            .font(.system(size: 22))
                            .foregroundColor(appState.browserControlEnabled ? Color.vAccent : Color.vMuted)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Screen Awareness")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(Color.vText)
                        Text(appState.browserControlEnabled ? "Active — Shiro is watching your screen" : "Inactive — Shiro is working blind")
                            .font(.system(size: 12))
                            .foregroundColor(Color.vMuted)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { appState.browserControlEnabled },
                        set: { appState.setBrowserControl($0) }
                    ))
                    .toggleStyle(.switch)
                    .tint(Color.vAccent)
                }
                .padding(18)
                .background(Color.vSurface)
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(
                            appState.browserControlEnabled ? Color.vAccent.opacity(0.35) : Color.vBorder,
                            lineWidth: 1
                        )
                )
                .cornerRadius(14)

                // Live summary
                if let summary = appState.latestScreenSummary {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("LAST CAPTURED")
                            .font(.custom("JetBrains Mono", size: 9.5))
                            .foregroundColor(Color.vDim)
                            .tracking(1.5)
                        Text(summary)
                            .font(.custom("JetBrains Mono", size: 12))
                            .foregroundColor(Color.vText)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.vSurface)
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
                        .foregroundColor(Color.vAccent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.vAccent.opacity(0.1))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(Color.vAccent.opacity(0.3), lineWidth: 1)
                        )
                        .cornerRadius(10)
                }
                .buttonStyle(.plain)

                // Privacy note
                VStack(alignment: .leading, spacing: 6) {
                    Label("Privacy", systemImage: "lock.shield")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Color.vMuted)
                    Text("Screenshots are analyzed locally by your active LLM backend. Nothing is sent to external servers unless you are using the Anthropic API or Claude CLI route, in which case screenshot descriptions are included in the prompt.")
                        .font(.system(size: 11))
                        .foregroundColor(Color.vDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(14)
                .background(Color.vSurface)
                .cornerRadius(10)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 28)
        }
        .background(Color.vBg)
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
                    .foregroundColor(Color.vText)
                Spacer()
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)
            .padding(.bottom, 8)

            // SettingsView is declared in FloatingBarView.swift (internal access)
            SettingsView()
                .environmentObject(appState)
        }
        .background(Color.vBg)
    }
}
