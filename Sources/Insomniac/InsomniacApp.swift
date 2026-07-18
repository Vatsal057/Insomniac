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
        registerAppleScriptCommands()
        MouseManager.shared.updateTimerState()

        if sleepManager.startSessionOnLaunch {
            sleepManager.enableSleep(duration: sleepManager.defaultDuration)
        }

        #if DEBUG
        UpdateChecker.selfCheck()
        #endif
        if UpdateChecker.autoCheckOnLaunch {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                UpdateChecker.checkForUpdates(silent: true)
            }
        }

        if sleepManager.isFirstLaunch {
            OnboardingManager.shared.show { [weak self] in
                self?.sleepManager.markFirstLaunchComplete()
            }
        }
    }

    // MARK: - URL scheme handler

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            handleURL(url)
        }
    }

    private func handleURL(_ url: URL) {
        guard url.scheme == "insomniac" else { return }

        let host = url.host?.lowercased()
        switch host {
        case "toggle":
            sleepManager.toggleSleep()
        case "enable":
            if let durationParam = url.queryParameter("duration") {
                sleepManager.enableSleep(duration: TimeInterval(durationParam))
            } else {
                sleepManager.enableSleep(duration: nil)
            }
        case "disable":
            sleepManager.disableSleep()
        case "status":
            break
        default:
            break
        }
    }

    // MARK: - AppleScript commands

    private func registerAppleScriptCommands() {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleAppleScriptCommand(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    @objc func handleAppleScriptCommand(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        guard let urlString = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: urlString) else { return }
        handleURL(url)
    }

    func applicationWillTerminate(_ notification: Notification) {
        tooltipTimer?.invalidate()
        MouseManager.shared.stop()
        LocationPickerManager.shared.close()
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
                guard let self else { return }
                self.updateIcon()
                self.updateTooltip()
                if self.sleepManager.isSleepDisabled && !self.sleepManager.useCaffeinate {
                    Watchdog.shared.beat()
                }
                self.sleepManager.checkBatteryCutoff()
            }
        }
    }

    // MARK: - Status item click

    @objc private func handleStatusClick(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let isRightClick = event?.type == .rightMouseUp ||
            (event?.type == .leftMouseUp && event?.modifierFlags.contains(.control) == true)

        let style = sleepManager.quickStartToggleStyle

        if style == "leftClickToggle" {
            if isRightClick {
                showMenu()
            } else {
                sleepManager.toggleSleep()
            }
        } else { // leftClickMenu
            let isAltClick = event?.modifierFlags.contains(.option) == true
            if isAltClick || isRightClick {
                sleepManager.toggleSleep()
            } else {
                showMenu()
            }
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
        status.image = NSImage(systemSymbolName: "moon.zzz.fill", accessibilityDescription: nil)
        menu.addItem(status)

        menu.addItem(.separator())

        let enable = NSMenuItem(
            title: "Enable Sleep Prevention",
            action: nil,
            keyEquivalent: ""
        )
        enable.isEnabled = true
        enable.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: nil)
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
        settings.image = NSImage(systemSymbolName: "gearshape.fill", accessibilityDescription: nil)
        menu.addItem(settings)

        menu.addItem(.separator())

        let updates = NSMenuItem(title: "Check for Updates\u{2026}", action: #selector(checkForUpdates), keyEquivalent: "")
        updates.target = self
        updates.image = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: nil)
        menu.addItem(updates)

        let version = appVersionString()
        let about = NSMenuItem(title: "About Insomniac \(version)", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        about.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: nil)
        menu.addItem(about)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Insomniac", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: nil)
        menu.addItem(quitItem)
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
        status.image = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil)
        menu.addItem(status)

        menu.addItem(.separator())

        let disable = NSMenuItem(
            title: "Disable Sleep Prevention",
            action: #selector(disableSleepAction),
            keyEquivalent: "t"
        )
        disable.target = self
        disable.image = NSImage(systemSymbolName: "power", accessibilityDescription: nil)
        menu.addItem(disable)

        menu.addItem(.separator())

        let settings = NSMenuItem(title: "Settings\u{2026}", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        settings.image = NSImage(systemSymbolName: "gearshape.fill", accessibilityDescription: nil)
        menu.addItem(settings)

        menu.addItem(.separator())

        let updates = NSMenuItem(title: "Check for Updates\u{2026}", action: #selector(checkForUpdates), keyEquivalent: "")
        updates.target = self
        updates.image = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: nil)
        menu.addItem(updates)

        let version = appVersionString()
        let about = NSMenuItem(title: "About Insomniac \(version)", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        about.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: nil)
        menu.addItem(about)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Insomniac", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: nil)
        menu.addItem(quitItem)
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

    @objc private func checkForUpdates() {
        UpdateChecker.checkForUpdates(silent: false)
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
        window.isReleasedWhenClosed = false
        window.styleMask = [.titled, .closable, .resizable]
        window.setContentSize(NSSize(width: 520, height: 520))
        window.minSize = NSSize(width: 500, height: 450)
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

}

extension URL {
    func queryParameter(_ name: String) -> String? {
        URLComponents(url: self, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == name })?
            .value
    }
}
