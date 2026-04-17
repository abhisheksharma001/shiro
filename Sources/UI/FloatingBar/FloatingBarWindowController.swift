import AppKit
import SwiftUI

// MARK: - Floating Bar Window
// Aesthetic direction: Dark Minimal / Terminal-inspired
// Font: JetBrains Mono (monospace identity) + SF Pro for UI
// Color: Near-black bg (#0D0D0D), Electric green accent (#00FF85), muted gray text
// Layout: Compact pill anchored to top-center, expands downward on focus
// Signature detail: Green pulse indicator on status dot, monospace typing

final class FloatingBarWindowController: NSWindowController {

    convenience init() {
        let window = FloatingBarWindow()
        self.init(window: window)
        setupWindow()
    }

    private func setupWindow() {
        guard let window = window as? FloatingBarWindow else { return }

        let contentView = FloatingBarView()
            .environmentObject(AppState.shared)

        window.contentView = NSHostingView(rootView: contentView)
        window.center()

        // Position at top center
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let windowWidth: CGFloat = 680
            let windowHeight: CGFloat = 60
            let x = screenFrame.midX - windowWidth / 2
            let y = screenFrame.maxY - windowHeight - 12
            window.setFrame(CGRect(x: x, y: y, width: windowWidth, height: windowHeight), display: false)
        }
    }

    func expandHeight(_ height: CGFloat) {
        guard let window = window else { return }
        var frame = window.frame
        let diff = height - frame.height
        frame.origin.y -= diff
        frame.size.height = height
        window.setFrame(frame, display: true, animate: true)
    }

    func collapseToBar() {
        guard let window = window else { return }
        var frame = window.frame
        let diff = frame.height - 60
        frame.origin.y += diff
        frame.size.height = 60
        window.setFrame(frame, display: true, animate: true)
    }
}

final class FloatingBarWindow: NSPanel {
    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = true
        acceptsMouseMovedEvents = true
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
