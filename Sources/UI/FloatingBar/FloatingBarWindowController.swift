import AppKit
import SwiftUI
import Combine

// MARK: - Floating Bar Window
// Compact pill anchored to top-center of screen.
//
// Sizing strategy: MANUAL.
// We deliberately do NOT use NSHostingController.sizingOptions = .preferredContentSize
// because that creates an Auto Layout feedback loop with the inner ScrollView once
// the chat thread grows — NSISEngine recurses through HostingScrollView.setFrameSize
// until the main-thread stack overflows (we crashed on this 2026-04-21 18:50, 19:19).
//
// Instead we expose AppState.isFloatingExpanded as a single source of truth, observe
// it via Combine, and animate the NSPanel frame between two fixed heights.

final class FloatingBarWindowController: NSWindowController {

    private static let barWidth:        CGFloat = 720
    private static let compactHeight:   CGFloat = 64
    private static let expandedHeight:  CGFloat = 540
    private static let topMargin:       CGFloat = 12

    private var cancellables = Set<AnyCancellable>()

    convenience init() {
        let window = FloatingBarWindow()
        self.init(window: window)
        setupWindow()
        observeExpansion()
    }

    private func setupWindow() {
        guard let window = window as? FloatingBarWindow else { return }

        let contentView = FloatingBarView()
            .environmentObject(AppState.shared)

        // Fixed-size hosting controller — no automatic resizing. The SwiftUI
        // root view always reports the SAME intrinsic size for a given window
        // size, so AutoLayout stays stable.
        let hosting = NSHostingController(rootView: contentView)
        window.contentViewController = hosting

        // Hard bounds — give Auto Layout no room to oscillate.
        window.minSize = NSSize(width: Self.barWidth, height: Self.compactHeight)
        window.maxSize = NSSize(width: Self.barWidth, height: Self.expandedHeight)

        positionAtTop(window: window, height: Self.compactHeight)
    }

    private func observeExpansion() {
        AppState.shared.$isFloatingExpanded
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] expanded in
                self?.applyExpansion(expanded)
            }
            .store(in: &cancellables)
    }

    private func applyExpansion(_ expanded: Bool) {
        guard let window else { return }
        let height = expanded ? Self.expandedHeight : Self.compactHeight
        positionAtTop(window: window, height: height, animated: true)
    }

    /// Re-anchor the window so its top edge sits `topMargin` below the menu bar
    /// of whichever screen the cursor is on. Keeps the bar visually pinned even
    /// as the height changes.
    private func positionAtTop(window: NSWindow, height: CGFloat, animated: Bool = false) {
        let screen = screenForCursor() ?? NSScreen.main
        guard let sf = screen?.visibleFrame else { return }
        let x = sf.midX - Self.barWidth / 2
        let y = sf.maxY - height - Self.topMargin
        let frame = CGRect(x: x, y: y, width: Self.barWidth, height: height)
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration              = 0.22
                ctx.allowsImplicitAnimation = true
                window.animator().setFrame(frame, display: true)
            }
        } else {
            window.setFrame(frame, display: false)
        }
    }

    private func screenForCursor() -> NSScreen? {
        let p = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(p) }
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
