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

    /// Longest session a URL is allowed to ask for (24h). Anything can hand us
    /// an `insomniac://` link — a web page, a stray shortcut — so a URL can't
    /// be trusted to set an unbounded countdown.
    private static let maxURLDuration: TimeInterval = 24 * 60 * 60

    private func handleURL(_ url: URL) {
        guard url.scheme?.lowercased() == "insomniac" else { return }

        let host = url.host?.lowercased()
        switch host {
        case "toggle":
            sleepManager.toggleSleep()
        case "enable":
            sleepManager.enableSleep(duration: Self.urlDuration(from: url))
        case "disable":
            sleepManager.disableSleep()
        case "status":
            break
        default:
            break
        }
    }

    /// Parses and clamps `?duration=` (seconds). Returns nil for "indefinite",
    /// which is also what a malformed or non-positive value falls back to.
    private static func urlDuration(from url: URL) -> TimeInterval? {
        guard let raw = url.queryParameter("duration"),
              let seconds = TimeInterval(raw),
              seconds.isFinite, seconds > 0 else { return nil }
        return min(seconds, maxURLDuration)
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

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard sleepManager.isSleepDisabled else { return .terminateNow }

        Task {
            await sleepManager.setSleepDisabled(false)
            NSApplication.shared.reply(toApplicationShouldTerminate: true)
        }

        // Restoring sleep shells out to pmset. If that stalls, an unanswered
        // `.terminateLater` leaves the app unquittable — the Watchdog is the
        // safety net for the flag, so give up rather than hang forever.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            NSApplication.shared.reply(toApplicationShouldTerminate: true)
        }

        return .terminateLater
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
                self?.startTooltipTimer()
                self?.observeState()
            }
        }
    }

    private func updateIcon() {
        if let button = statusItem.button {
            let name = sleepManager.isSleepDisabled ? "eye" : "eye.slash"
            button.image = NSImage(systemSymbolName: name, accessibilityDescription: "Insomniac")

            if sleepManager.showMenuBarCountdown,
               sleepManager.isSleepDisabled,
               let remaining = sleepManager.formatRemainingTime() {
                button.imagePosition = .imageLeft
                button.attributedTitle = NSAttributedString(
                    string: " " + remaining,
                    attributes: [
                        .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
                        .foregroundColor: Brand.activeNS
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

    /// Keeps the menu bar countdown ticking — but only if the user asked for a
    /// countdown, and only while one is actually running.
    ///
    /// This timer used to run every 30 seconds for the whole session doing three
    /// jobs. Two of them are gone: the watchdog no longer needs a heartbeat (it
    /// detects death through a pipe now), and the low-battery cutoff is driven by
    /// IOKit power notifications. What's left is cosmetic, so it's opt-in.
    ///
    /// With the countdown off — the default — an active session runs no timers
    /// at all. The remaining time is still shown, computed on demand, whenever
    /// the menu is opened.
    private func startTooltipTimer() {
        tooltipTimer?.invalidate()
        tooltipTimer = nil

        guard sleepManager.showMenuBarCountdown,
              sleepManager.isSleepDisabled,
              sleepManager.sleepDisabledUntil != nil else { return }

        // The display only ever shows whole minutes, so align to the minute
        // rather than ticking twice as often as anything can change.
        let timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.updateIcon()
                self.updateTooltip()
            }
        }
        // Wide slack so macOS folds this into a wake it was already making.
        timer.tolerance = 15
        tooltipTimer = timer
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
        // Recompute on open. With no repeating timer, this is what keeps the
        // remaining time honest — and it's the only moment anyone can read it.
        updateIcon()
        updateTooltip()

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
        status.image = NSImage(systemSymbolName: "eye.slash", accessibilityDescription: nil)
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
        
        if let defaultDuration = sleepManager.defaultDuration,
           !SleepManager.DurationOption.presets.contains(where: { $0.seconds == defaultDuration }) {
            let customOption = SleepManager.DurationOption.custom(seconds: defaultDuration)
            let item = NSMenuItem(
                title: customOption.title,
                action: #selector(enableWithDuration(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = customOption.seconds
            item.state = .on
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
        status.attributedTitle = styledTitle(statusText, color: Brand.activeNS)
        status.image = NSImage(systemSymbolName: "eye", accessibilityDescription: nil)
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
        // `isVisible` is false for a window the user closed with the red X, but
        // `isReleasedWhenClosed = false` means it's still alive and still ours.
        // Reopening it beats abandoning it and building another.
        if let existing = settingsWindow {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hostingController = NSHostingController(rootView: SettingsView())
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Insomniac Settings"
        window.isReleasedWhenClosed = false
        window.styleMask = [.titled, .closable, .resizable]
        window.setContentSize(NSSize(width: 560, height: 700))
        window.minSize = NSSize(width: 500, height: 560)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow = window
    }

    private var aboutWindow: NSWindow?

    @objc private func showAbout() {
        if let existing = aboutWindow {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = AboutView { [weak self] in
            self?.aboutWindow?.close()
            self?.aboutWindow = nil
        }

        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "About Insomniac"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 380, height: 320))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        aboutWindow = window
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

struct AboutView: View {
    let onClose: () -> Void

    var versionString: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "Version \(version) (\(build))"
    }

    var body: some View {
        VStack(spacing: 18) {
            BrandEyeIcon(size: 80)

            VStack(spacing: 4) {
                Text("Insomniac")
                    .font(.system(size: 22, weight: .bold, design: .rounded))

                Text(versionString)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Text("A calm, lightweight macOS menu bar utility that keeps your Mac awake — even with the lid closed.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)

            HStack(spacing: 12) {
                Button("GitHub Repository") {
                    if let url = URL(string: "https://github.com/Vatsal057/Insomniac") {
                        NSWorkspace.shared.open(url)
                    }
                }

                Button("Close") {
                    onClose()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 4)
        }
        .padding(24)
        .frame(width: 380, height: 320)
    }
}
