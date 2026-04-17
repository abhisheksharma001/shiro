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

                    // ── Expanded Chat Area ────────────────────────────
                    if isExpanded {
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
                // Mic button
                micButton

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

        messages.append(DisplayMessage(role: .user, content: text))
        // Placeholder streaming bubble.
        messages.append(DisplayMessage(role: .assistant, content: ""))
        isTyping = true
        appState.isProcessing = true
        appState.agentStatus = .thinking

        // Wire up streaming tokens into the last message.
        coordinator.onStreamingToken = { [self] token in
            guard let last = messages.indices.last else { return }
            var updated = messages[last]
            updated = DisplayMessage(role: .assistant, content: updated.content + token)
            messages[last] = updated
        }
        coordinator.onTurnComplete = { [self] _ in
            isTyping = false
            appState.isProcessing = false
            appState.agentStatus = .idle
            coordinator.onStreamingToken = nil
            coordinator.onTurnComplete = nil
        }

        Task {
            do {
                _ = try await coordinator.send(query: text)
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
                Text(message.content)
                    .font(.custom("JetBrains Mono", size: 12))
                    .foregroundColor(Color(hex: "#0D0D0D"))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(accent)
                    .cornerRadius(12)
                    .cornerRadius(3, corners: .topRight)
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

    enum MessageRole { case user, assistant }
}

// MARK: - Settings View (placeholder)

struct SettingsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Form {
            Section("Models") {
                LabeledContent("Brain", value: Config.brainModel)
                LabeledContent("Vision", value: Config.visionModel)
                LabeledContent("Fast", value: Config.fastModel)
                LabeledContent("Embeddings", value: Config.embeddingModel)
            }
            Section("Status") {
                LabeledContent("LM Studio", value: appState.lmStudioConnected ? "✅ Connected" : "❌ Disconnected")
                LabeledContent("Deepgram STT", value: Config.deepgramEnabled ? "✅ Enabled" : "Using LM Studio Whisper")
            }
        }
        .formStyle(.grouped)
        .frame(width: 400, height: 280)
        .padding()
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
