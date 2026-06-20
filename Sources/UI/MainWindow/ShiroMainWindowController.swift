import AppKit
import SwiftUI

// MARK: - ShiroMainWindowController
//
// Singleton controller for the full Shiro workspace window.
// The floating bar's expand button calls ShiroMainWindowController.shared.show().
// The window is created lazily on first show and re-used on subsequent shows.

@MainActor
final class ShiroMainWindowController: NSWindowController {

    static let shared = ShiroMainWindowController()

    private init() {
        let window = ShiroMainWindow()
        super.init(window: window)
        buildContent(window: window)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show() {
        guard let window else { return }
        if !window.isVisible {
            // Re-center on the screen that currently has the cursor
            if let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main {
                let sf = screen.visibleFrame
                let w: CGFloat = 1120
                let h: CGFloat = 760
                window.setFrame(CGRect(x: sf.midX - w / 2, y: sf.midY - h / 2, width: w, height: h), display: false)
            }
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildContent(window: NSWindow) {
        let rootView = ShiroMainWindowView()
            .environmentObject(AppState.shared)

        let hosting = NSHostingController(rootView: rootView)
        window.contentViewController = hosting
        window.setContentSize(NSSize(width: 1120, height: 760))
    }
}

// MARK: - ShiroMainWindow (NSWindow subclass)

final class ShiroMainWindow: NSWindow {
    init() {
        super.init(
            contentRect: .zero,
            styleMask:   [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing:     .buffered,
            defer:       false
        )
        title                                    = "Shiro"
        titlebarAppearsTransparent               = true
        titleVisibility                          = .hidden
        isMovableByWindowBackground              = true
        backgroundColor                          = NSColor(red: 0.027, green: 0.035, blue: 0.059, alpha: 1)
        minSize                                  = NSSize(width: 820, height: 560)
        isReleasedWhenClosed                     = false   // keep alive for re-use
        collectionBehavior                       = [.managed, .fullScreenPrimary]
        hasShadow                                = true
    }
}
