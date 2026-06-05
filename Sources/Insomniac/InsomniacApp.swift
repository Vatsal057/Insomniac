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
    private var tooltipTimer: Timer?

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
        startTooltipTimer()

        if sleepManager.isFirstLaunch {
            showWelcomeAlert()
            sleepManager.markFirstLaunchComplete()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        tooltipTimer?.invalidate()
    }

    // MARK: - State observation

    private func observeState() {
        withObservationTracking {
            _ = sleepManager.isSleepDisabled
            _ = sleepManager.sleepDisabledUntil
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

            if sleepManager.isSleepDisabled, let remaining = sleepManager.formatRemainingTime() {
                button.imagePosition = .imageLeft
                button.attributedTitle = NSAttributedString(
                    string: " " + remaining,
                    attributes: [
                        .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
                        .foregroundColor: NSColor.systemOrange
                    ]
                )
            } else {
                button.attributedTitle = NSAttributedString(string: "")
            }
        }
    }

    private func updateTooltip() {
        if let button = statusItem.button {
            if let remaining = sleepManager.formatRemainingTime() {
                button.toolTip = "Insomniac — Sleep Prevention: ON (\(remaining) remaining)"
            } else {
                let state = sleepManager.isSleepDisabled ? "ON" : "OFF"
                button.toolTip = "Insomniac — Sleep Prevention: \(state)"
            }
        }
    }

    private func startTooltipTimer() {
        tooltipTimer?.invalidate()
        tooltipTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateIcon()
                self?.updateTooltip()
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

        if sleepManager.isSleepDisabled {
            addActiveStateMenu(to: menu)
        } else {
            addInactiveStateMenu(to: menu)
        }

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    private func addInactiveStateMenu(to menu: NSMenu) {
        let status = NSMenuItem(title: "Sleep Prevention: OFF", action: nil, keyEquivalent: "")
        status.isEnabled = false
        status.attributedTitle = styledTitle(
            "Sleep Prevention: OFF",
            color: .secondaryLabelColor
        )
        menu.addItem(status)

        menu.addItem(.separator())

        let enable = NSMenuItem(
            title: "Enable Sleep Prevention",
            action: nil,
            keyEquivalent: ""
        )
        enable.isEnabled = false
        menu.addItem(enable)

        let submenu = NSMenu()
        submenu.autoenablesItems = false

        for option in SleepManager.DurationOption.presets {
            let item = NSMenuItem(
                title: option.title,
                action: #selector(enableWithDuration(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = option.seconds
            if option.seconds == sleepManager.defaultDuration {
                item.state = .on
            }
            submenu.addItem(item)
        }

        submenu.addItem(.separator())

        let indefinite = NSMenuItem(
            title: SleepManager.DurationOption.indefinite.title,
            action: #selector(enableIndefinite),
            keyEquivalent: ""
        )
        indefinite.target = self
        if sleepManager.defaultDuration == nil {
            indefinite.state = .on
        }
        submenu.addItem(indefinite)

        enable.submenu = submenu
        menu.setSubmenu(submenu, for: enable)

        menu.addItem(.separator())

        let settings = NSMenuItem(title: "Settings\u{2026}", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())

        let version = appVersionString()
        let about = NSMenuItem(title: "About Insomniac \(version)", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        menu.addItem(.separator())

        menu.addItem(NSMenuItem(title: "Quit Insomniac", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func addActiveStateMenu(to menu: NSMenu) {
        let statusText: String
        if let remaining = sleepManager.formatRemainingTime() {
            statusText = "Sleep Prevention: ON \u{00B7} \(remaining) left"
        } else {
            statusText = "Sleep Prevention: ON"
        }

        let status = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
        status.isEnabled = false
        status.attributedTitle = styledTitle(statusText, color: .systemOrange)
        menu.addItem(status)

        menu.addItem(.separator())

        let disable = NSMenuItem(
            title: "Disable Sleep Prevention",
            action: #selector(disableSleepAction),
            keyEquivalent: "t"
        )
        disable.target = self
        menu.addItem(disable)

        menu.addItem(.separator())

        let settings = NSMenuItem(title: "Settings\u{2026}", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())

        let version = appVersionString()
        let about = NSMenuItem(title: "About Insomniac \(version)", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        menu.addItem(.separator())

        menu.addItem(NSMenuItem(title: "Quit Insomniac", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func styledTitle(_ text: String, color: NSColor) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: NSFont.menuFont(ofSize: 13),
            .foregroundColor: color
        ])
    }

    private func appVersionString() -> String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "v\(version) (\(build))"
    }

    // MARK: - Actions

    @objc private func enableWithDuration(_ sender: NSMenuItem) {
        guard let seconds = sender.representedObject as? TimeInterval else { return }
        sleepManager.enableSleep(duration: seconds)
    }

    @objc private func enableIndefinite() {
        sleepManager.enableSleep(duration: nil)
    }

    @objc private func disableSleepAction() {
        sleepManager.disableSleep()
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
        window.setContentSize(NSSize(width: 420, height: 320))
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

            How to use it:
            \u{2022} Left-click the menu bar icon to toggle sleep prevention
            \u{2022} Right-click to pick a duration and access settings
            \u{2022} Use \u{2318}\u{2325}I to toggle from anywhere

            On first toggle, macOS will ask for your password to configure \
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
