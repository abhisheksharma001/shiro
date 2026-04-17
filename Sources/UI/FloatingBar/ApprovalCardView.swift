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

    private let bg       = Color(hex: "#0D0D0D")
    private let amber    = Color(hex: "#FFB800")
    private let red      = Color(hex: "#FF4545")
    private let green    = Color(hex: "#00FF85")
    private let muted    = Color(hex: "#3A3A3A")
    private let textC    = Color(hex: "#E8E8E8")
    private let subtext  = Color(hex: "#888888")

    @State private var showFullInput: Bool = false

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

            // ── Requested time ────────────────────────────────────────
            Text("Requested \(timeAgo(approval.requestedAt))")
                .font(.custom("JetBrains Mono", size: 10))
                .foregroundColor(subtext)
                .padding(.horizontal, 14)
                .padding(.top, 6)

            Divider()
                .background(muted)
                .padding(.horizontal, 14)
                .padding(.top, 12)

            // ── Action buttons ────────────────────────────────────────
            HStack(spacing: 10) {
                // Remember Deny — soft destructive
                Button {
                    onDecide(.rememberDeny)
                } label: {
                    Text("Never Allow")
                        .font(.custom("JetBrains Mono", size: 11))
                        .foregroundColor(subtext)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Color(hex: "#1A1A1A"))
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .strokeBorder(muted, lineWidth: 1)
                        )
                        .cornerRadius(5)
                }
                .buttonStyle(.plain)

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

                // Approve
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
    }

    // MARK: - Helpers

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

// MARK: - Approval Queue Overlay

/// Renders all pending approvals as a stacked overlay above the floating bar.
struct ApprovalQueueOverlay: View {
    @ObservedObject var gate: ConsentGate

    var body: some View {
        VStack(spacing: 8) {
            ForEach(gate.pendingApprovals) { approval in
                ApprovalCardView(approval: approval) { decision in
                    gate.resolve(callId: approval.callId, decision: decision)
                }
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
