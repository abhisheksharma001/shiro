import AppKit
import SwiftUI

// MARK: - Floating Bar Window
// Compact pill anchored to top-center of screen.
// Auto-resizes via NSHostingController.sizingOptions = .preferredContentSize
// so the SwiftUI layout drives the window height without any manual frame math.

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

        let hosting = NSHostingController(rootView: contentView)
        if #available(macOS 13, *) {
            hosting.sizingOptions = .preferredContentSize
        }

        window.contentViewController = hosting

        // Width is fixed; height expands as SwiftUI content grows.
        window.minSize = NSSize(width: 700, height: 60)
        window.maxSize = NSSize(width: 700, height: 760)

        positionAtTopCenter(window: window, width: 700, compactHeight: 60)
    }

    private func positionAtTopCenter(window: NSWindow, width: CGFloat, compactHeight: CGFloat) {
        guard let screen = NSScreen.main else { return }
        let sf = screen.visibleFrame
        let x  = sf.midX - width / 2
        let y  = sf.maxY - compactHeight - 12
        window.setFrame(CGRect(x: x, y: y, width: width, height: compactHeight), display: false)
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
        isOpaque                    = false
        backgroundColor             = .clear
        hasShadow                   = true
        level                       = .floating
        collectionBehavior          = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = true
        acceptsMouseMovedEvents     = true
    }

    override var canBecomeKey:  Bool { true  }
    override var canBecomeMain: Bool { false }
}
