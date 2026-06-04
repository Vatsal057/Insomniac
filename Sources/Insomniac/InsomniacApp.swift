import SwiftUI
import ServiceManagement
import KeyboardShortcuts

@main
struct InsomniacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)

        if KeyboardShortcuts.getShortcut(for: .toggleSleep) == nil {
            KeyboardShortcuts.setShortcut(.init(.i, modifiers: [.command, .option]), for: .toggleSleep)
        }
    }

    var body: some Scene {
        Settings {
            SettingsView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let sleepManager = SleepManager.shared
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.action = #selector(handleStatusClick(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            updateIcon()
        }

        KeyboardShortcuts.onKeyDown(for: .toggleSleep) {
            SleepManager.shared.toggleSleep()
        }

        observeState()
    }

    private func observeState() {
        withObservationTracking {
            _ = sleepManager.isSleepDisabled
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.updateIcon()
                self?.observeState()
            }
        }
    }

    func updateIcon() {
        if let button = statusItem.button {
            let name = sleepManager.isSleepDisabled ? "bolt.fill" : "moon.zzz.fill"
            button.image = NSImage(systemSymbolName: name, accessibilityDescription: "Insomniac")
        }
    }

    @objc private func handleStatusClick(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp ||
            (event?.type == .leftMouseUp && event?.modifierFlags.contains(.control) == true) {
            showMenu()
        } else {
            sleepManager.toggleSleep()
        }
    }

    private func showMenu() {
        let menu = NSMenu()

        let status = NSMenuItem(title: "Sleep Prevention: \(sleepManager.isSleepDisabled ? "ON" : "OFF")", action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)

        menu.addItem(.separator())

        let toggle = NSMenuItem(title: sleepManager.isSleepDisabled ? "Re-enable Sleep" : "Disable Sleep",
                                action: #selector(toggleSleep), keyEquivalent: "t")
        toggle.target = self
        menu.addItem(toggle)

        let autoDeactivate = NSMenuItem(title: "Deactivate on Sleep", action: #selector(toggleAutoDeactivate), keyEquivalent: "")
        autoDeactivate.target = self
        autoDeactivate.state = sleepManager.autoDeactivateOnSleep ? .on : .off
        menu.addItem(autoDeactivate)

        menu.addItem(.separator())

        let settings = NSMenuItem(title: "Settings\u{2026}", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())

        menu.addItem(NSMenuItem(title: "Quit Insomniac", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func toggleSleep() {
        sleepManager.toggleSleep()
    }

    @objc private func toggleAutoDeactivate() {
        sleepManager.autoDeactivateOnSleep.toggle()
    }

    @objc private func openSettings() {
        if let existing = settingsWindow, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hostingController = NSHostingController(rootView: SettingsView())
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Insomniac Settings"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 350, height: 200))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow = window
    }
}
