import SwiftUI
import AppKit

@main
struct ShiroApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState.shared

    var body: some Scene {
        // Preferences window (⌘,) — lightweight tab view
        Settings {
            SettingsView()
                .environmentObject(appState)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var floatingBarController: FloatingBarWindowController?
    private var statusItem:            NSStatusItem?
    private var globalKeyMonitor:      Any?
    private var localKeyMonitor:       Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide from dock — we live in menu bar + floating panel + full window
        NSApp.setActivationPolicy(.accessory)

        setupMenuBarIcon()
        setupFloatingBar()
        setupHotkey()

        Task { await AppState.shared.initialize() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let g = globalKeyMonitor { NSEvent.removeMonitor(g); globalKeyMonitor = nil }
        if let l = localKeyMonitor  { NSEvent.removeMonitor(l); localKeyMonitor  = nil }
    }

    // MARK: - Menu bar

    private func setupMenuBarIcon() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem?.button else { return }
        button.image = NSImage(systemSymbolName: "waveform.circle.fill", accessibilityDescription: "Shiro")
        button.image?.isTemplate = true

        let menu = NSMenu()
        menu.addItem(menuItem("Open Shiro Workspace",   action: #selector(openMainWindow),  key: ""))
        menu.addItem(menuItem("Show/Hide floating bar",  action: #selector(showFloatingBar), key: "."))
        menu.addItem(.separator())
        menu.addItem(menuItem("Preferences…",           action: #selector(openPreferences), key: ","))
        menu.addItem(.separator())
        menu.addItem(menuItem("New Conversation",       action: #selector(clearConversation), key: ""))
        menu.addItem(.separator())
        menu.addItem(menuItem("Quit Shiro",             action: #selector(NSApplication.terminate(_:)), key: "q"))
        statusItem?.menu = menu
    }

    private func menuItem(_ title: String, action: Selector, key: String) -> NSMenuItem {
        NSMenuItem(title: title, action: action, keyEquivalent: key)
    }

    // MARK: - Floating bar

    private func setupFloatingBar() {
        floatingBarController = FloatingBarWindowController()
        floatingBarController?.showWindow(nil)
    }

    // MARK: - ⌘. hotkey — show/hide floating bar from anywhere

    private func setupHotkey() {
        // keyCode 47 = Period (".")
        let handler: (NSEvent) -> Void = { [weak self] event in
            guard event.modifierFlags.contains(.command),
                  event.keyCode == 47 else { return }
            self?.toggleFloatingBar()
        }

        // Global monitor fires even when Shiro is not the frontmost app.
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: handler)

        // Local monitor fires when the floating panel or main window is key.
        // Returns nil to consume the event so it doesn't propagate as a "." character.
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.modifierFlags.contains(.command) && event.keyCode == 47 {
                self.toggleFloatingBar()
                return nil
            }
            return event
        }
    }

    private func toggleFloatingBar() {
        guard let window = floatingBarController?.window else { return }
        if window.isVisible {
            window.orderOut(nil)
        } else {
            floatingBarController?.showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    // MARK: - Actions

    @objc private func openMainWindow() {
        Task { @MainActor in ShiroMainWindowController.shared.show() }
    }

    @objc private func showFloatingBar() {
        toggleFloatingBar()
    }

    @objc private func openPreferences() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    @objc private func clearConversation() {
        Task { @MainActor in AppState.shared.clearConversation() }
    }
}
