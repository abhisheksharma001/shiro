/*
 AESTHETIC: Consent Gate — High-stakes Alert
 ─────────────────────────────────────────────
 This card appears over the floating bar when Shiro wants to do something
 high-risk (write files, run shell commands, control the Mac UI, etc.).

 Design: Sharp-edged dark card with amber warning band at top.
 Colour:  #0D0D0D background, #FFB800 amber accent, #FF4545 deny red.
 Font:    JetBrains Mono for tool names + args; SF Pro for prose.
 Layout:  Full input dump so the user sees EXACTLY what will happen.
          Approve / Deny / Remember Deny — three clear actions.
*/

import SwiftUI

struct ApprovalCardView: View {
    let approval: ConsentGate.PendingApproval
    let onDecide: (ConsentGate.ApprovalDecision) -> Void
    /// Optional STT service — when non-nil and isRecording, voice keywords resolve the card.
    var stt: STTService? = nil

    private let bg       = Color(hex: "#0D0D0D")
    private let amber    = Color(hex: "#FFB800")
    private let red      = Color(hex: "#FF4545")
    private let green    = Color(hex: "#00FF85")
    private let muted    = Color(hex: "#3A3A3A")
    private let textC    = Color(hex: "#E8E8E8")
    private let subtext  = Color(hex: "#888888")

    @State private var showFullInput:    Bool = false
    @State private var secondsLeft:      Int  = Int(Config.approvalTimeoutSeconds)
    /// Last voice-resolved keyword shown briefly in the UI, cleared after 2s.
    @State private var voiceHint:        String? = nil

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // ── Amber warning band ─────────────────────────────────────
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.black)
                    .font(.system(size: 12, weight: .bold))
                Text("HIGH-RISK ACTION")
                    .font(.custom("JetBrains Mono", size: 11))
                    .fontWeight(.bold)
                    .foregroundColor(.black)
                    .tracking(1.5)
                Spacer()
                // Voice indicator — shows only when STT is live
                if let stt, stt.isRecording {
                    HStack(spacing: 4) {
                        if let hint = voiceHint {
                            Text(hint.uppercased())
                                .font(.custom("JetBrains Mono", size: 9))
                                .fontWeight(.bold)
                                .foregroundColor(.black)
                                .transition(.opacity)
                        } else {
                            Image(systemName: "mic.fill")
                                .font(.system(size: 9))
                                .foregroundColor(.black)
                                .symbolEffect(.pulse)
                            Text("VOICE ON")
                                .font(.custom("JetBrains Mono", size: 9))
                                .fontWeight(.bold)
                                .foregroundColor(.black)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.black.opacity(0.2))
                    .cornerRadius(3)
                }
                riskBadge
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(amber)

            // ── Tool name + session ────────────────────────────────────
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(approval.toolName)
                        .font(.custom("JetBrains Mono", size: 14))
                        .fontWeight(.semibold)
                        .foregroundColor(amber)
                    Text("·")
                        .foregroundColor(subtext)
                    Text(approval.sessionKey)
                        .font(.custom("JetBrains Mono", size: 11))
                        .foregroundColor(subtext)
                }
                if let just = approval.justification, !just.isEmpty {
                    Text(just)
                        .font(.system(size: 12))
                        .foregroundColor(textC)
                        .lineLimit(3)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)

            // ── Input dump ────────────────────────────────────────────
            VStack(alignment: .leading, spacing: 4) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { showFullInput.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: showFullInput ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .medium))
                        Text("ARGUMENTS")
                            .font(.custom("JetBrains Mono", size: 10))
                            .tracking(1)
                    }
                    .foregroundColor(subtext)
                }
                .buttonStyle(.plain)

                if showFullInput {
                    ScrollView {
                        Text(prettyInput)
                            .font(.custom("JetBrains Mono", size: 11))
                            .foregroundColor(Color(hex: "#AAAAAA"))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 160)
                    .padding(10)
                    .background(Color(hex: "#111111"))
                    .cornerRadius(6)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)

            // ── Requested time + countdown ───────────────────────────
            HStack {
                Text("Requested \(timeAgo(approval.requestedAt))")
                    .font(.custom("JetBrains Mono", size: 10))
                    .foregroundColor(subtext)
                Spacer()
                HStack(spacing: 4) {
                    Image(systemName: "timer")
                        .font(.system(size: 9))
                        .foregroundColor(secondsLeft < 60 ? red : subtext)
                    Text("Auto-deny in \(countdownString)")
                        .font(.custom("JetBrains Mono", size: 10))
                        .foregroundColor(secondsLeft < 60 ? red : subtext)
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 6)
            .onReceive(timer) { _ in
                if secondsLeft > 0 { secondsLeft -= 1 }
            }

            Divider()
                .background(muted)
                .padding(.horizontal, 14)
                .padding(.top, 12)

            // ── Action buttons ────────────────────────────────────────
            VStack(spacing: 8) {
                // Top row: primary actions (Deny / Approve)
                HStack(spacing: 10) {
                    Spacer()

                    // Deny
                    Button {
                        onDecide(.denied(reason: nil))
                    } label: {
                        Text("Deny")
                            .font(.custom("JetBrains Mono", size: 12))
                            .fontWeight(.semibold)
                            .foregroundColor(red)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 7)
                            .background(red.opacity(0.12))
                            .overlay(
                                RoundedRectangle(cornerRadius: 5)
                                    .strokeBorder(red.opacity(0.5), lineWidth: 1)
                            )
                            .cornerRadius(5)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.escape)

                    // Approve (once)
                    Button {
                        onDecide(.approved)
                    } label: {
                        Text("Approve")
                            .font(.custom("JetBrains Mono", size: 12))
                            .fontWeight(.semibold)
                            .foregroundColor(.black)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 7)
                            .background(green)
                            .cornerRadius(5)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.return)
                }

                // Bottom row: persistent policies (Never / Always)
                HStack(spacing: 10) {
                    // Never Allow — soft destructive
                    Button {
                        onDecide(.rememberDeny)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "hand.raised.fill")
                                .font(.system(size: 9))
                            Text("Never Allow")
                                .font(.custom("JetBrains Mono", size: 11))
                        }
                        .foregroundColor(subtext)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color(hex: "#1A1A1A"))
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .strokeBorder(muted, lineWidth: 1)
                        )
                        .cornerRadius(5)
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    // Always Allow — persistent approve
                    Button {
                        onDecide(.rememberAllow)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "checkmark.shield.fill")
                                .font(.system(size: 9))
                            Text("Always Allow")
                                .font(.custom("JetBrains Mono", size: 11))
                        }
                        .foregroundColor(green)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(green.opacity(0.10))
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .strokeBorder(green.opacity(0.4), lineWidth: 1)
                        )
                        .cornerRadius(5)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut("a", modifiers: [.command, .shift])
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .background(bg)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(amber.opacity(0.4), lineWidth: 1)
        )
        .cornerRadius(10)
        .shadow(color: amber.opacity(0.15), radius: 20)
        .frame(width: 380)
        // Voice approval: observe STT lastSegment for keywords
        .onChange(of: stt?.lastSegment ?? "") { _, segment in
            handleVoiceSegment(segment)
        }
    }

    // MARK: - Voice approval

    /// Checks the transcribed segment for approval keywords.
    /// Supported: "approve"/"yes" → .approved | "deny"/"no" → .denied |
    ///            "always" → .rememberAllow | "never" → .rememberDeny
    private func handleVoiceSegment(_ segment: String) {
        guard let stt, stt.isRecording, !segment.isEmpty else { return }
        let lower = segment.lowercased()
        let decision: ConsentGate.ApprovalDecision?
        let hint: String
        if lower.contains("always") {
            decision = .rememberAllow; hint = "ALWAYS ✓"
        } else if lower.contains("never") {
            decision = .rememberDeny;  hint = "NEVER ✗"
        } else if lower.contains("approve") || lower.hasSuffix(" yes") || lower == "yes" {
            decision = .approved;      hint = "APPROVED ✓"
        } else if lower.contains("deny") || lower.hasSuffix(" no") || lower == "no" {
            decision = .denied(reason: "Voice denial"); hint = "DENIED ✗"
        } else {
            return  // not a keyword — ignore
        }
        // Show the hint briefly, then resolve
        withAnimation { voiceHint = hint }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            if let d = decision { onDecide(d) }
        }
    }

    // MARK: - Helpers

    private var countdownString: String {
        let m = secondsLeft / 60
        let s = secondsLeft % 60
        return String(format: "%d:%02d", m, s)
    }

    private var riskBadge: some View {
        Text(approval.risk.rawValue.uppercased())
            .font(.custom("JetBrains Mono", size: 9))
            .fontWeight(.bold)
            .tracking(1)
            .foregroundColor(.black)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.black.opacity(0.2))
            .cornerRadius(3)
    }

    private var prettyInput: String {
        guard let data = try? JSONSerialization.data(withJSONObject: approval.input,
                                                     options: .prettyPrinted),
              let str = String(data: data, encoding: .utf8) else {
            return approval.input.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
        }
        return str
    }

    private func timeAgo(_ date: Date) -> String {
        let secs = Int(-date.timeIntervalSinceNow)
        if secs < 5  { return "just now" }
        if secs < 60 { return "\(secs)s ago" }
        return "\(secs / 60)m ago"
    }
}

// MARK: - Veto Toast Queue

/// Lightweight 3-second veto toasts for medium-risk auto-approved actions.
struct VetoToastQueue: View {
    @ObservedObject var gate: ConsentGate

    var body: some View {
        VStack(spacing: 6) {
            ForEach(gate.activeVetoToasts) { toast in
                VetoToastCard(toast: toast) {
                    gate.vetoMediumRiskAction(callId: toast.id)
                }
                .transition(.asymmetric(
                    insertion: .move(edge: .top).combined(with: .opacity),
                    removal:   .scale(scale: 0.9).combined(with: .opacity)
                ))
            }
        }
        .animation(.spring(response: 0.25, dampingFraction: 0.85), value: gate.activeVetoToasts.count)
        .padding(.horizontal, 12)
    }
}

private struct VetoToastCard: View {
    let toast: ConsentGate.VetoToast
    let onVeto: () -> Void

    private let amber  = Color(hex: "#FFB800")
    private let bg     = Color(hex: "#1A1916")
    private let border = Color(hex: "#3A3530")

    var body: some View {
        HStack(spacing: 10) {
            // Countdown ring
            ZStack {
                Circle()
                    .stroke(border, lineWidth: 2)
                    .frame(width: 26, height: 26)
                Circle()
                    .trim(from: 0, to: CGFloat(toast.secondsLeft) / 3.0)
                    .stroke(amber, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 26, height: 26)
                    .animation(.linear(duration: 1), value: toast.secondsLeft)
                Text("\(toast.secondsLeft)")
                    .font(.custom("JetBrains Mono", size: 9))
                    .foregroundColor(amber)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("MEDIUM RISK — AUTO-APPROVING")
                    .font(.custom("JetBrains Mono", size: 9))
                    .fontWeight(.bold)
                    .tracking(0.6)
                    .foregroundColor(amber.opacity(0.7))
                Text(toast.toolName)
                    .font(.custom("JetBrains Mono", size: 11))
                    .foregroundColor(Color(hex: "#F2EDE5"))
            }

            Spacer()

            Button("Veto") { onVeto() }
                .font(.custom("JetBrains Mono", size: 11))
                .fontWeight(.semibold)
                .foregroundColor(.black)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(amber)
                .cornerRadius(4)
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(bg)
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(amber.opacity(0.35), lineWidth: 1))
        .cornerRadius(8)
        .shadow(color: amber.opacity(0.10), radius: 8)
    }
}

// MARK: - Approval Queue Overlay

/// Renders all pending approvals as a stacked overlay above the floating bar.
struct ApprovalQueueOverlay: View {
    @ObservedObject var gate: ConsentGate
    /// Passed through to each card for voice-keyword resolution.
    var stt: STTService? = nil

    var body: some View {
        VStack(spacing: 8) {
            ForEach(gate.pendingApprovals) { approval in
                ApprovalCardView(approval: approval, onDecide: { decision in
                    gate.resolve(callId: approval.callId, decision: decision)
                }, stt: stt)
                .transition(.asymmetric(
                    insertion: .move(edge: .top).combined(with: .opacity),
                    removal:   .scale(scale: 0.95).combined(with: .opacity)
                ))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: gate.pendingApprovals.count)
        .padding(.horizontal, 12)
    }
}
