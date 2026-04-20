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
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide from dock — we live in menu bar + floating panel + full window
        NSApp.setActivationPolicy(.accessory)

        setupMenuBarIcon()
        setupFloatingBar()

        Task { await AppState.shared.initialize() }
    }

    // MARK: - Menu bar

    private func setupMenuBarIcon() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem?.button else { return }
        button.image = NSImage(systemSymbolName: "waveform.circle.fill", accessibilityDescription: "Shiro")
        button.image?.isTemplate = true

        let menu = NSMenu()
        menu.addItem(menuItem("Open Shiro Workspace",   action: #selector(openMainWindow),  key: ""))
        menu.addItem(menuItem("Show floating bar",      action: #selector(showFloatingBar), key: ""))
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

    // MARK: - Actions

    @objc private func openMainWindow() {
        Task { @MainActor in ShiroMainWindowController.shared.show() }
    }

    @objc private func showFloatingBar() {
        floatingBarController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openPreferences() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    @objc private func clearConversation() {
        Task { @MainActor in AppState.shared.clearConversation() }
    }
}
