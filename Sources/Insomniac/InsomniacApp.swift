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
            updateTooltip()
        }

        KeyboardShortcuts.onKeyDown(for: .toggleSleep) {
            SleepManager.shared.toggleSleep()
        }

        sleepManager.requestNotificationPermission()
        observeState()

        if sleepManager.isFirstLaunch {
            showWelcomeAlert()
            sleepManager.markFirstLaunchComplete()
        }
    }

    // MARK: - State observation

    private func observeState() {
        withObservationTracking {
            _ = sleepManager.isSleepDisabled
            _ = sleepManager.remainingTime
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.updateIcon()
                self?.updateTooltip()
                self?.observeState()
            }
        }
    }

    private func updateIcon() {
        if let button = statusItem.button {
            let name = sleepManager.isSleepDisabled ? "bolt.fill" : "moon.zzz.fill"
            button.image = NSImage(systemSymbolName: name, accessibilityDescription: "Insomniac")
        }
    }

    private func updateTooltip() {
        if let button = statusItem.button {
            if sleepManager.isSleepDisabled, sleepManager.sleepDisableDeadline != nil {
                let time = sleepManager.formatTime(sleepManager.remainingTime)
                button.toolTip = "Insomniac — Sleep Prevention: ON (\(time) remaining)"
            } else {
                let state = sleepManager.isSleepDisabled ? "ON" : "OFF"
                button.toolTip = "Insomniac — Sleep Prevention: \(state)"
            }
        }
    }

    // MARK: - Status item click

    @objc private func handleStatusClick(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp ||
            (event?.type == .leftMouseUp && event?.modifierFlags.contains(.control) == true) {
            showMenu()
        } else {
            sleepManager.toggleSleep()
        }
    }

    // MARK: - Menu

    private func showMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false

        // Status
        let statusTitle: String
        if sleepManager.isSleepDisabled, sleepManager.sleepDisableDeadline != nil {
            let time = sleepManager.formatTime(sleepManager.remainingTime)
            statusTitle = "Sleep Prevention: ON (\(time))"
        } else {
            statusTitle = sleepManager.isSleepDisabled ? "Sleep Prevention: ON" : "Sleep Prevention: OFF"
        }
        let status = NSMenuItem(title: statusTitle, action: nil, keyEquivalent: "")
        status.isEnabled = false
        let statusColor: NSColor = sleepManager.isSleepDisabled ? .systemOrange : .secondaryLabelColor
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.menuFont(ofSize: 13),
            .foregroundColor: statusColor
        ]
        status.attributedTitle = NSAttributedString(string: statusTitle, attributes: attrs)
        menu.addItem(status)

        menu.addItem(.separator())

        // Toggle
        let toggleTitle = sleepManager.isSleepDisabled ? "Disable Sleep Prevention" : "Enable Sleep Prevention"
        let toggle = NSMenuItem(title: toggleTitle, action: #selector(toggleSleep), keyEquivalent: "t")
        toggle.target = self
        menu.addItem(toggle)

        // Duration submenu
        if !sleepManager.isSleepDisabled {
            let durationItem = NSMenuItem(title: "Set Duration", action: nil, keyEquivalent: "")
            let durationMenu = NSMenu()

            let durations: [(String, TimeInterval)] = [
                ("30 minutes", 1800),
                ("1 hour", 3600),
                ("2 hours", 7200),
                ("4 hours", 14400),
                ("8 hours", 28800),
            ]

            for (label, interval) in durations {
                let item = NSMenuItem(title: label, action: #selector(setDuration(_:)), keyEquivalent: "")
                item.target = self
                item.tag = Int(interval)
                durationMenu.addItem(item)
            }

            durationMenu.addItem(.separator())

            let untilQuit = NSMenuItem(title: "Until I quit", action: #selector(setDurationUntilQuit), keyEquivalent: "")
            untilQuit.target = self
            durationMenu.addItem(untilQuit)

            durationItem.submenu = durationMenu
            menu.addItem(durationItem)
        }

        // Cancel timer
        if sleepManager.isSleepDisabled, sleepManager.sleepDisableDeadline != nil {
            let cancel = NSMenuItem(title: "Cancel Timer", action: #selector(cancelTimer), keyEquivalent: "")
            cancel.target = self
            menu.addItem(cancel)
        }

        // Auto-deactivate
        let autoDeactivate = NSMenuItem(title: "Auto-Deactivate on Sleep", action: #selector(toggleAutoDeactivate), keyEquivalent: "")
        autoDeactivate.target = self
        autoDeactivate.state = sleepManager.autoDeactivateOnSleep ? .on : .off
        menu.addItem(autoDeactivate)

        menu.addItem(.separator())

        // Shortcut hint
        if let shortcut = KeyboardShortcuts.getShortcut(for: .toggleSleep) {
            let shortcutHint = NSMenuItem(title: "Toggle: \(shortcut.description)", action: nil, keyEquivalent: "")
            shortcutHint.isEnabled = false
            menu.addItem(shortcutHint)
        }

        // Settings
        let settings = NSMenuItem(title: "Settings\u{2026}", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())

        // About
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        let about = NSMenuItem(title: "About Insomniac v\(version) (\(build))", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        menu.addItem(.separator())

        // Quit
        let quit = NSMenuItem(title: "Quit Insomniac", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    // MARK: - Actions

    @objc private func toggleSleep() {
        sleepManager.toggleSleep()
    }

    @objc private func setDuration(_ sender: NSMenuItem) {
        let duration = TimeInterval(sender.tag)
        sleepManager.startSleepDisableTimer(duration)
        sleepManager.toggleSleep()
    }

    @objc private func setDurationUntilQuit() {
        sleepManager.toggleSleep()
    }

    @objc private func cancelTimer() {
        sleepManager.cancelTimer()
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
        window.setContentSize(NSSize(width: 380, height: 220))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow = window
    }

    @objc private func showAbout() {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"

        let alert = NSAlert()
        alert.messageText = "Insomniac"
        alert.informativeText = """
            Version \(version) (\(build))

            A macOS menu bar app that keeps your Mac awake, \
            even with the lid closed.

            Built with Swift and IOKit.
            """
        alert.icon = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil)
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - First launch

    private func showWelcomeAlert() {
        let alert = NSAlert()
        alert.messageText = "Welcome to Insomniac"
        alert.informativeText = """
            Insomniac keeps your Mac awake even when the lid is closed.

            How it works:
            \u{2022} Left-click the menu bar icon to toggle sleep prevention
            \u{2022} Right-click for options and settings
            \u{2022} Use \u{2318}\u{2325}I to toggle from anywhere
            \u{2022} Set a duration so sleep prevention turns off automatically

            On first use, macOS will ask for your password to configure \
            sleep settings. This only happens once.
            """
        alert.icon = NSImage(systemSymbolName: "moon.zzz.fill", accessibilityDescription: nil)
        alert.addButton(withTitle: "Get Started")
        alert.addButton(withTitle: "Quit")
        alert.alertStyle = .informational

        let response = alert.runModal()
        if response == .alertSecondButtonReturn {
            NSApp.terminate(nil)
        }
    }
}
