/*
 AESTHETIC: Meeting Mode — War Room
 ────────────────────────────────────
 Background:  #0D0D0D
 Accent:      #00FF85 (live / active)
 Amber:       #FFB800 (recording indicator)
 Text:        #E8E8E8
 Subtext:     #5A5A5A

 Layout:    Compact header bar (recording indicator + timer + controls)
            Scrolling live transcript below
            Auto-summary card when Shiro processes a flush
 Signature: Pulsing amber REC dot, monospace transcript lines,
            green flash when a new segment arrives
*/

import SwiftUI
import MarkdownUI

struct MeetingModeView: View {
    @EnvironmentObject var appState: AppState
    let onEnd: ([TranscriptLine]) -> Void   // called with full transcript on "End Meeting"

    @State private var lines:      [TranscriptLine] = []
    @State private var elapsed:    TimeInterval = 0
    @State private var timer:      Timer? = nil
    @State private var flashId:    UUID? = nil           // triggers green flash on new line
    @State private var summary:    String? = nil         // auto-summary from periodic flush
    @State private var isSummarising = false
    /// Identifies the most-recent in-flight summarise request so streaming
    /// callbacks from earlier requests can't clobber the latest summary.
    @State private var currentSummariseId: UUID? = nil

    private let bg      = Color(hex: "#0D0D0D")
    private let accent  = Color(hex: "#00FF85")
    private let amber   = Color(hex: "#FFB800")
    private let muted   = Color(hex: "#3A3A3A")
    private let textC   = Color(hex: "#E8E8E8")
    private let subtext = Color(hex: "#5A5A5A")

    var body: some View {
        VStack(spacing: 0) {
            // ── Header ──────────────────────────────────────────────────
            header

            Divider().background(muted)

            // ── Transcript scroll ────────────────────────────────────────
            transcriptArea

            // ── Auto-summary card ────────────────────────────────────────
            if let summary {
                Divider().background(muted)
                summaryCard(summary)
            }

            // ── Footer controls ──────────────────────────────────────────
            Divider().background(muted)
            footer
        }
        .onAppear {
            startTimer()
            hookSTT()
        }
        .onDisappear {
            timer?.invalidate()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            // Pulsing REC dot
            ZStack {
                Circle()
                    .fill(amber.opacity(0.25))
                    .frame(width: 22, height: 22)
                    .scaleEffect(appState.isListening ? 1.5 : 1.0)
                    .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true),
                               value: appState.isListening)
                Circle().fill(amber).frame(width: 8, height: 8)
            }

            Text("REC")
                .font(.custom("JetBrains Mono", size: 10))
                .fontWeight(.bold)
                .foregroundColor(amber)
                .tracking(2)

            Text(formatElapsed(elapsed))
                .font(.custom("JetBrains Mono", size: 13))
                .foregroundColor(textC)
                .monospacedDigit()

            Spacer()

            Text("\(lines.count) segments")
                .font(.custom("JetBrains Mono", size: 10))
                .foregroundColor(subtext)

            // Summarise now button
            Button {
                summariseNow()
            } label: {
                Label("Summarise", systemImage: "text.badge.checkmark")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(isSummarising ? subtext : accent)
            }
            .buttonStyle(.plain)
            .disabled(isSummarising || lines.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Transcript

    private var transcriptArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(lines) { line in
                        TranscriptLineView(line: line,
                                           accent: accent,
                                           textColor: textC,
                                           subtext: subtext,
                                           isNew: line.id == flashId)
                            .id(line.id)
                    }
                    if lines.isEmpty {
                        Text("Listening for speech…")
                            .font(.custom("JetBrains Mono", size: 12))
                            .foregroundColor(subtext)
                            .padding(.vertical, 20)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
                .padding(12)
            }
            .frame(maxHeight: 280)
            .onChange(of: lines.count) { _, _ in
                withAnimation { proxy.scrollTo(lines.last?.id) }
            }
        }
    }

    // MARK: - Summary card

    private func summaryCard(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(Color(hex: "#7B7BFF")).frame(width: 6, height: 6)
                Text("auto-summary")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(Color(hex: "#7B7BFF"))
                Spacer()
                Button {
                    withAnimation { summary = nil }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9))
                        .foregroundColor(subtext)
                }
                .buttonStyle(.plain)
            }
            Markdown(text)
                .markdownTheme(.shiroTheme)
                .font(.system(size: 11))
        }
        .padding(12)
        .background(Color(hex: "#111111"))
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            // Mic toggle
            Button {
                toggleMic()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: appState.isListening ? "mic.fill" : "mic.slash.fill")
                        .font(.system(size: 12))
                    Text(appState.isListening ? "Mute" : "Unmute")
                        .font(.custom("JetBrains Mono", size: 11))
                }
                .foregroundColor(appState.isListening ? accent : subtext)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(appState.isListening ? accent.opacity(0.1) : Color.clear)
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(appState.isListening ? accent.opacity(0.4) : muted, lineWidth: 1)
                )
                .cornerRadius(5)
            }
            .buttonStyle(.plain)

            Spacer()

            // End meeting
            Button {
                endMeeting()
            } label: {
                Text("End Meeting")
                    .font(.custom("JetBrains Mono", size: 12))
                    .fontWeight(.semibold)
                    .foregroundColor(.black)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .background(Color(hex: "#FF4545"))
                    .cornerRadius(5)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Actions

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            elapsed += 1
        }
    }

    private func hookSTT() {
        guard let stt = appState.stt else { return }

        // Receive segments and append to transcript
        stt.onSegment = { segment in
            guard segment.isFinal else { return }
            Task { @MainActor in
                let line = TranscriptLine(text: segment.text, timestamp: Date())
                lines.append(line)
                flashId = line.id
                // Clear flash after 800ms
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    if flashId == line.id { flashId = nil }
                }
            }
        }

        // Wire periodic flush to auto-summary
        stt.onMeetingFlush = { segments in
            Task { @MainActor in
                guard !segments.isEmpty else { return }
                let joined = segments.map(\.text).joined(separator: "\n")
                await autoSummarise(transcript: joined)
            }
        }

        // Ensure STT is actually running
        if !appState.isListening {
            appState.isListening = true
            appState.agentStatus = .listening
            stt.startMeetingMode()
        }
    }

    private func toggleMic() {
        guard let stt = appState.stt else { return }
        if appState.isListening {
            appState.isListening = false
            appState.agentStatus = .idle
            _ = stt.stopMeetingMode()
        } else {
            appState.isListening = true
            appState.agentStatus = .listening
            stt.startMeetingMode()
        }
    }

    private func autoSummarise(transcript: String) async {
        guard !isSummarising,
              let skills      = appState.skillsRegistry,
              let skill       = skills.skill(named: "summarise-meeting"),
              let coordinator = appState.agentCoordinator else { return }
        isSummarising = true
        defer { isSummarising = false }

        let prompt    = skill.fillTemplate(args: ["transcript": transcript])
        let requestId = UUID()

        // Per-request token buffer so a newer summarise request can't mix
        // tokens into an older request's summary.
        final class Slot { var buf = ""; let id: UUID; init(id: UUID) { self.id = id } }
        let slot = Slot(id: requestId)
        currentSummariseId = requestId

        // ── Set callbacks BEFORE send() — otherwise the bridge's first
        //    text_delta can arrive before we subscribe and we lose tokens.
        coordinator.onStreamingToken = { token in
            slot.buf += token
        }
        coordinator.onTurnComplete = { _ in
            // Only apply if this turn is still the latest one we care about.
            if currentSummariseId == slot.id {
                withAnimation { summary = slot.buf.isEmpty ? nil : slot.buf }
                coordinator.onStreamingToken = nil
                coordinator.onTurnComplete   = nil
            }
        }

        do {
            _ = try await coordinator.send(
                query:        prompt,
                systemPrompt: skill.systemPrompt
            )
        } catch {
            print("[MeetingMode] auto-summarise error: \(error.localizedDescription)")
        }
    }

    private func summariseNow() {
        let transcript = lines.map(\.text).joined(separator: "\n")
        Task { await autoSummarise(transcript: transcript) }
    }

    private func endMeeting() {
        // Stop STT
        appState.isListening = false
        appState.agentStatus = .idle
        _ = appState.stt?.stopMeetingMode()
        timer?.invalidate()

        // Trigger full summarise-meeting skill with complete transcript
        let allLines = lines
        if let skills = appState.skillsRegistry,
           let skill  = skills.skill(named: "summarise-meeting"),
           !allLines.isEmpty {
            let full = allLines.map { "[\(formatTime($0.timestamp))] \($0.text)" }.joined(separator: "\n")
            let prompt = skill.fillTemplate(args: ["transcript": full])
            Task {
                try? await appState.agentCoordinator?.send(
                    query: prompt,
                    systemPrompt: skill.systemPrompt
                )
            }
        }

        // Persist meeting session to DB
        Task {
            if let db = appState.database, !allLines.isEmpty {
                let transcript = allLines.map(\.text).joined(separator: "\n")
                let session = MeetingSession(
                    id: UUID().uuidString,
                    title: "Meeting \(DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .short))",
                    fullTranscript: transcript,
                    summary: summary,
                    actionItemsJSON: nil,
                    participantsJSON: nil,
                    startedAt: Date().addingTimeInterval(-elapsed),
                    endedAt: Date(),
                    createdAt: Date()
                )
                // Immutable snapshot for the Sendable closure capture.
                let snap = session
                try? await db.pool.write { conn in
                    var row = snap
                    try row.insert(conn)
                }
            }
        }

        // Transition back to normal mode
        appState.isMeetingMode = false
        onEnd(allLines)
    }

    // MARK: - Helpers

    private func formatElapsed(_ t: TimeInterval) -> String {
        let h = Int(t) / 3600
        let m = (Int(t) % 3600) / 60
        let s = Int(t) % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%02d:%02d", m, s)
    }

    private func formatTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: date)
    }
}

// MARK: - Transcript Line Model

struct TranscriptLine: Identifiable {
    let id = UUID()
    let text: String
    let timestamp: Date
}

// MARK: - Transcript Line View

struct TranscriptLineView: View {
    let line: TranscriptLine
    let accent: Color
    let textColor: Color
    let subtext: Color
    let isNew: Bool

    private var timeStr: String {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        return f.string(from: line.timestamp)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(timeStr)
                .font(.custom("JetBrains Mono", size: 9))
                .foregroundColor(subtext)
                .frame(width: 56, alignment: .leading)
                .padding(.top, 2)

            Text(line.text)
                .font(.system(size: 12))
                .foregroundColor(isNew ? accent : textColor)
                .animation(.easeOut(duration: 0.4), value: isNew)
                .textSelection(.enabled)
        }
    }
}
