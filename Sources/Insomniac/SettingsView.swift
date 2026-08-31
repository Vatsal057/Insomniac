import SwiftUI
import KeyboardShortcuts
import ServiceManagement

struct SettingsView: View {
    @Bindable var sleepManager = SleepManager.shared
    @Bindable var mouseManager = MouseManager.shared

    @State private var selectedTab = "general"
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var autoCheckUpdates = UpdateChecker.autoCheckOnLaunch
    @State private var watchedApps: [WatchedApp] = []

    @State private var isAccessibilityTrusted = AXIsProcessTrusted()

    struct WatchedApp: Identifiable {
        var id: String { bundleID }
        let bundleID: String
        let name: String
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            generalTab
                .tabItem {
                    Label("General", systemImage: "gearshape.fill")
                }
                .tag("general")

            sessionDefaultsTab
                .tabItem {
                    Label("Session Defaults", systemImage: "clock.fill")
                }
                .tag("defaults")

            cursorControlsTab
                .tabItem {
                    Label("Cursor", systemImage: "cursorarrow.motionlines")
                }
                .tag("cursor")

            triggersTab
                .tabItem {
                    Label("Triggers", systemImage: "bolt.badge.a.fill")
                }
                .tag("triggers")
        }
        .padding(16)
        .frame(minWidth: 540, idealHeight: 660)
        .onAppear {
            loadWatchedApps()
            isAccessibilityTrusted = AXIsProcessTrusted()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            isAccessibilityTrusted = AXIsProcessTrusted()
        }
    }

    // MARK: - Tab 1: General

    private var generalTab: some View {
        ScrollView {
            VStack(spacing: 16) {
                settingsSection(title: "Launch & Window Behavior", systemImage: "macwindow") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("Launch at login", isOn: $launchAtLogin)
                            .onChange(of: launchAtLogin) { _, newValue in
                                if newValue {
                                    try? SMAppService.mainApp.register()
                                } else {
                                    try? SMAppService.mainApp.unregister()
                                }
                            }

                        Toggle("Start session when Insomniac launches", isOn: $sleepManager.startSessionOnLaunch)

                        VStack(alignment: .leading, spacing: 6) {
                            Text("Quick-Start Toggle Style")
                                .font(.subheadline)
                                .fontWeight(.medium)

                            Picker("", selection: $sleepManager.quickStartToggleStyle) {
                                Text("Left-click toggles session (Right-click menu)").tag("leftClickToggle")
                                Text("Left-click opens menu (Right-click/Option-click toggles)").tag("leftClickMenu")
                            }
                            .labelsHidden()
                            .pickerStyle(.radioGroup)
                        }
                    }
                }

                settingsSection(title: "Power & Engine Settings", systemImage: "battery.100") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("Only enable sleep prevention while on AC power", isOn: $sleepManager.requireCharging)

                        Toggle("Use caffeinate mode (no sudo required)", isOn: $sleepManager.useCaffeinate)
                            .onChange(of: sleepManager.useCaffeinate) { _, _ in
                                if sleepManager.isSleepDisabled {
                                    Task { @MainActor in
                                        await sleepManager.setSleepDisabled(false)
                                        sleepManager.enableSleep(duration: sleepManager.remainingTime)
                                    }
                                }
                            }

                        Text("Caffeinate mode prevents idle sleep only. It does not keep your Mac awake when the lid is closed.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Divider()

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Passwordless pmset access")
                                .font(.callout.weight(.medium))
                            Text("pmset mode installs one sudoers rule (`/etc/sudoers.d/insomniac`) so Insomniac can toggle sleep without asking for your password each time. It stays on this Mac until you remove it — even if you delete the app.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)

                            Button("Remove sudoers Rule\u{2026}") {
                                revokeSudoersRule()
                            }
                            .controlSize(.small)
                        }
                    }
                }

                settingsSection(title: "Thermal & Battery Safety", systemImage: "exclamationmark.shield.fill") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("Pause sleep prevention when Mac runs hot", isOn: $sleepManager.thermalGuardEnabled)

                        if sleepManager.thermalGuardEnabled {
                            Picker("Trip at:", selection: $sleepManager.thermalGuardCriticalOnly) {
                                Text("Serious heat").tag(false)
                                Text("Critical heat only").tag(true)
                            }
                            .pickerStyle(.segmented)
                        }

                        Divider()

                        Toggle("Disable on low battery", isOn: $sleepManager.batteryCutoffEnabled)

                        if sleepManager.batteryCutoffEnabled {
                            HStack {
                                Text("Cutoff threshold:")
                                Spacer()
                                Text("\(sleepManager.batteryCutoffPercent)%")
                                    .font(.system(.body, design: .monospaced))
                                    .bold()
                                    .foregroundStyle(.secondary)
                            }
                            Slider(value: Binding(
                                get: { Double(sleepManager.batteryCutoffPercent) },
                                set: { sleepManager.batteryCutoffPercent = Int($0) }
                            ), in: 5...50, step: 5)
                        }
                    }
                }

                settingsSection(title: "Lid & Display", systemImage: "display") {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Dim screen on lid close only while on battery", isOn: $sleepManager.dimOnBatteryOnly)
                        Toggle("Skip dimming when an external display is connected", isOn: $sleepManager.skipDimOnExternalDisplay)
                    }
                }

                settingsSection(title: "Updates & Tools", systemImage: "arrow.triangle.2.circlepath") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Insomniac \(versionString())")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Check for Updates\u{2026}") {
                                UpdateChecker.checkForUpdates(silent: false)
                            }
                        }

                        Toggle("Check for updates automatically on launch", isOn: $autoCheckUpdates)
                            .onChange(of: autoCheckUpdates) { _, v in
                                UpdateChecker.autoCheckOnLaunch = v
                            }

                        Divider()

                        HStack {
                            Button("Welcome Guide\u{2026}") {
                                OnboardingManager.shared.show {}
                            }
                            Spacer()
                            Button("Export Settings\u{2026}") { SettingsIO.exportSettings() }
                            Button("Import Settings\u{2026}") { SettingsIO.importSettings() }
                        }
                    }
                }
            }
            .padding(12)
        }
    }

    // MARK: - Tab 2: Session Defaults

    private var sessionDefaultsTab: some View {
        ScrollView {
            VStack(spacing: 16) {
                settingsSection(title: "Default Session Duration", systemImage: "clock.fill") {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("Default Duration Shortcut:", selection: Binding(
                            get: { currentDefaultOption() },
                            set: { option in
                                if option.id == "custom" {
                                    // Default to 45 minutes if they just selected "Custom..."
                                    if sleepManager.defaultDuration == nil || SleepManager.DurationOption.presets.contains(where: { $0.seconds == sleepManager.defaultDuration }) {
                                        sleepManager.defaultDuration = 45 * 60
                                    }
                                } else {
                                    sleepManager.defaultDuration = option.seconds
                                }
                            }
                        )) {
                            Text("Indefinitely").tag(SleepManager.DurationOption.indefinite)
                            ForEach(SleepManager.DurationOption.presets) { option in
                                Text(option.title).tag(option)
                            }
                            Text("Custom...").tag(SleepManager.DurationOption.custom)
                        }
                        .pickerStyle(.menu)

                        if currentDefaultOption().id.starts(with: "custom") {
                            HStack {
                                Text("Duration (minutes):")
                                TextField("", value: Binding(
                                    get: { Int((sleepManager.defaultDuration ?? (45 * 60)) / 60) },
                                    set: { sleepManager.defaultDuration = TimeInterval(max(1, $0) * 60) }
                                ), format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 80)
                            }
                        }

                        Toggle("Auto-deactivate when device is put to sleep manually", isOn: $sleepManager.autoDeactivateOnSleep)
                    }
                }

                settingsSection(title: "Keyboard Activation Shortcut", systemImage: "keyboard") {
                    VStack(alignment: .leading, spacing: 8) {
                        KeyboardShortcuts.Recorder("Global Activation Shortcut:", name: .toggleSleep)
                        Text("Default shortcut is ⌘⌥I. You can toggle sleep prevention globally from any application.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(12)
        }
    }

    // MARK: - Tab 3: Cursor Controls

    private var cursorControlsTab: some View {
        ScrollView {
            VStack(spacing: 16) {
                settingsSection(title: "Cursor Automation", systemImage: "cursorarrow.motionlines") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 20) {
                            Toggle("Jiggle Cursor", isOn: $mouseManager.isJigglerEnabled)
                            Toggle("Enable Clicker", isOn: $mouseManager.isClickerEnabled)
                        }

                        Text("Cursor actions run only while sleep prevention is active.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if (mouseManager.isJigglerEnabled || mouseManager.isClickerEnabled) && !isAccessibilityTrusted {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.title3)
                                    .foregroundStyle(.orange)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Accessibility Permission Required")
                                        .font(.subheadline.bold())
                                    Text("Cursor movement and click automation require Accessibility access.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Button("Grant Permission in Settings\u{2026}") {
                                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                                            NSWorkspace.shared.open(url)
                                        }
                                    }
                                    .font(.caption)
                                    .padding(.top, 2)
                                }
                            }
                            .padding(12)
                            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }

                        if mouseManager.isJigglerEnabled || mouseManager.isClickerEnabled {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Trigger Interval")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)

                                Picker("", selection: $mouseManager.interval) {
                                    Text("10s").tag(10.0)
                                    Text("30s").tag(30.0)
                                    Text("1m").tag(60.0)
                                    Text("5m").tag(300.0)
                                    Text("15m").tag(900.0)
                                }
                                .pickerStyle(.segmented)
                            }

                            Toggle("Only move/click when system is idle", isOn: $mouseManager.onlyWhenIdle)

                            if mouseManager.onlyWhenIdle {
                                HStack {
                                    Text("Inactivity delay:")
                                        .font(.subheadline)
                                    Slider(value: $mouseManager.inactivityDelay, in: 5...300, step: 5)
                                    Text(formatIdleTimeout(mouseManager.inactivityDelay))
                                        .font(.system(.body, design: .monospaced))
                                        .frame(width: 60, alignment: .trailing)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                if mouseManager.isJigglerEnabled || mouseManager.isClickerEnabled {
                    settingsSection(title: "Motion Speed", systemImage: "speedometer") {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Movement Speed:")
                                Spacer()
                                Text(mouseManager.speed >= 0.85 ? "Fast" : (mouseManager.speed >= 0.45 ? "Medium" : "Smooth"))
                                    .font(.subheadline.bold())
                                    .foregroundStyle(.secondary)
                            }

                            HStack(spacing: 12) {
                                Image(systemName: "tortoise.fill")
                                    .foregroundStyle(.secondary)
                                Slider(value: $mouseManager.speed, in: 0.1...1.0, step: 0.05)
                                Image(systemName: "hare.fill")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                if mouseManager.isClickerEnabled {
                    settingsSection(title: "Clicker Configuration", systemImage: "hand.tap.fill") {
                        VStack(alignment: .leading, spacing: 12) {
                            Picker("Click Action Type:", selection: $mouseManager.clickType) {
                                Text("Left Click").tag("left")
                                Text("Right Click").tag("right")
                                Text("Middle Click").tag("middle")
                                Text("Double Click").tag("double")
                                Text("None (Move Only)").tag("none")
                            }
                            .pickerStyle(.menu)

                            if mouseManager.clickType != "none" {
                                HStack {
                                    Label {
                                        Text("X: \(Int(mouseManager.clickX))  Y: \(Int(mouseManager.clickY))")
                                            .font(.system(.body, design: .monospaced))
                                            .bold()
                                    } icon: {
                                        Image(systemName: "scope")
                                            .foregroundStyle(Brand.color)
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                                    Spacer()

                                    Button {
                                        LocationPickerManager.shared.startPicking { point in
                                            mouseManager.clickX = point.x
                                            mouseManager.clickY = point.y
                                        }
                                    } label: {
                                        Label("Select Target\u{2026}", systemImage: "scope")
                                    }
                                }

                                Toggle("Return cursor to original location after click", isOn: $mouseManager.returnCursor)
                            }
                        }
                    }
                }
            }
            .padding(12)
        }
    }

    // MARK: - Tab 4: Triggers

    private var triggersTab: some View {
        ScrollView {
            VStack(spacing: 16) {
                settingsSection(title: "Schedule", systemImage: "calendar.badge.clock") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("Keep awake on a weekly schedule", isOn: $sleepManager.scheduleEnabled)
                            .onChange(of: sleepManager.scheduleEnabled) { _, _ in
                                sleepManager.startSchedule()
                            }

                        if sleepManager.scheduleEnabled {
                            HStack(spacing: 8) {
                                ForEach(1...7, id: \.self) { day in
                                    let symbol = Calendar.current.veryShortWeekdaySymbols[day - 1]
                                    let isSelected = sleepManager.scheduleDays.contains(day)
                                    Button {
                                        if isSelected {
                                            sleepManager.scheduleDays.remove(day)
                                        } else {
                                            sleepManager.scheduleDays.insert(day)
                                        }
                                        sleepManager.startSchedule()
                                    } label: {
                                        Text(symbol)
                                            .font(.subheadline.bold())
                                            .frame(width: 32, height: 32)
                                            .background(isSelected ? Brand.color : Color.primary.opacity(0.08), in: Circle())
                                            .foregroundStyle(isSelected ? .white : .primary)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }

                            HStack(spacing: 16) {
                                DatePicker("From:", selection: timeBinding(
                                    hour: sleepManager.scheduleStartHour,
                                    minute: sleepManager.scheduleStartMinute,
                                    onChange: { h, m in
                                        sleepManager.scheduleStartHour = h
                                        sleepManager.scheduleStartMinute = m
                                        sleepManager.startSchedule()
                                    }
                                ), displayedComponents: .hourAndMinute)

                                DatePicker("To:", selection: timeBinding(
                                    hour: sleepManager.scheduleEndHour,
                                    minute: sleepManager.scheduleEndMinute,
                                    onChange: { h, m in
                                        sleepManager.scheduleEndHour = h
                                        sleepManager.scheduleEndMinute = m
                                        sleepManager.startSchedule()
                                    }
                                ), displayedComponents: .hourAndMinute)
                            }
                        }
                    }
                }

                settingsSection(title: "File Download Watcher", systemImage: "arrow.down.circle.fill") {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Enable File Download Watcher", isOn: $sleepManager.downloadWatcherEnabled)

                        if sleepManager.downloadWatcherEnabled {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Watching Folder:")
                                    .font(.caption)
                                    .bold()
                                HStack {
                                    Text(sleepManager.downloadWatcherPath)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer()
                                    Button("Select Folder\u{2026}") {
                                        selectDownloadFolder()
                                    }
                                }
                            }
                            .padding(10)
                            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                    }
                }

                settingsSection(title: "Watched Applications", systemImage: "app.fill") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Keep awake while any of these applications are running:")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        ForEach(watchedApps) { app in
                            HStack {
                                Image(systemName: "app.fill")
                                    .foregroundStyle(Brand.color)
                                VStack(alignment: .leading) {
                                    Text(app.name)
                                        .font(.subheadline.bold())
                                    Text(app.bundleID)
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                                Spacer()
                                Button {
                                    removeWatchedApp(app.bundleID)
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                        .foregroundStyle(.red)
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        Button("Add Application\u{2026}") {
                            addWatchedApp()
                        }
                    }
                }

            }
            .padding(12)
        }
    }

    // MARK: - Actions

    private func revokeSudoersRule() {
        guard sleepManager.hasInstalledSudoersRule() else {
            let info = NSAlert()
            info.messageText = "Nothing to remove"
            info.informativeText = "No Insomniac sudoers rule is installed on this Mac."
            info.addButton(withTitle: "OK")
            info.runModal()
            return
        }

        let confirm = NSAlert()
        confirm.messageText = "Remove the sudoers rule?"
        confirm.informativeText = "Insomniac will ask for your admin password every time it toggles sleep in pmset mode. Caffeinate mode is unaffected."
        confirm.alertStyle = .warning
        confirm.addButton(withTitle: "Remove")
        confirm.addButton(withTitle: "Cancel")
        guard confirm.runModal() == .alertFirstButtonReturn else { return }

        Task { @MainActor in
            if sleepManager.isSleepDisabled {
                await sleepManager.setSleepDisabled(false)
            }
            let removed = await sleepManager.revokePermissions()
            let result = NSAlert()
            result.messageText = removed ? "Rule removed" : "Couldn't remove the rule"
            result.informativeText = removed
                ? "/etc/sudoers.d/insomniac has been deleted."
                : "The rule is still in place. You can remove it manually with: sudo rm /etc/sudoers.d/insomniac"
            result.alertStyle = removed ? .informational : .warning
            result.addButton(withTitle: "OK")
            result.runModal()
        }
    }

    // MARK: - Components & Helpers

    private func settingsSection<Content: View>(
        title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.headline)
                    .foregroundStyle(Brand.color)
                Text(title)
                    .font(.headline)
            }

            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    private func timeBinding(
        hour: Int,
        minute: Int,
        onChange: @escaping (Int, Int) -> Void
    ) -> Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(
                    bySettingHour: hour,
                    minute: minute,
                    second: 0,
                    of: Date()
                ) ?? Date()
            },
            set: { newDate in
                let components = Calendar.current.dateComponents([.hour, .minute], from: newDate)
                onChange(components.hour ?? 0, components.minute ?? 0)
            }
        )
    }

    private func currentDefaultOption() -> SleepManager.DurationOption {
        let current = sleepManager.defaultDuration
        if let current,
           let match = SleepManager.DurationOption.presets.first(where: { $0.seconds == current }) {
            return match
        }
        if current != nil {
            return SleepManager.DurationOption.custom
        }
        return .indefinite
    }

    private func loadWatchedApps() {
        let bundleIDs = sleepManager.watchedAppBundleIDs
        watchedApps = bundleIDs.map { bundleID in
            let name = appName(for: bundleID) ?? bundleID
            return WatchedApp(bundleID: bundleID, name: name)
        }
    }

    private func appName(for bundleID: String) -> String? {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return nil
    }

    private func addWatchedApp() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = "Choose an Application"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let bundle = Bundle(url: url), let bundleID = bundle.bundleIdentifier else { return }

        var current = sleepManager.watchedAppBundleIDs
        guard !current.contains(bundleID) else { return }
        current.append(bundleID)
        sleepManager.watchedAppBundleIDs = current
        sleepManager.updateWatchedApps()
        loadWatchedApps()
    }

    private func removeWatchedApp(_ bundleID: String) {
        var current = sleepManager.watchedAppBundleIDs
        current.removeAll { $0 == bundleID }
        sleepManager.watchedAppBundleIDs = current
        sleepManager.updateWatchedApps()
        loadWatchedApps()
    }

    private func selectDownloadFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "Select Watch Folder"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        sleepManager.downloadWatcherPath = url.path
    }

    private func versionString() -> String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "v\(version) (\(build))"
    }

    private func formatIdleTimeout(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        if total < 60 {
            return "\(total)s"
        } else {
            let mins = total / 60
            let secs = total % 60
            return secs > 0 ? "\(mins)m \(secs)s" : "\(mins)m"
        }
    }
}
