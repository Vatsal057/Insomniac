import SwiftUI
import KeyboardShortcuts
import ServiceManagement

struct SettingsView: View {
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var autoDeactivate = SleepManager.shared.autoDeactivateOnSleep
    @State private var useCaffeinate = SleepManager.shared.useCaffeinate
    @State private var requireCharging = SleepManager.shared.requireCharging
    @State private var defaultDuration: SleepManager.DurationOption = currentDefaultOption()
    @State private var watchedApps: [WatchedApp] = []
    @State private var scheduleEnabled = SleepManager.shared.scheduleEnabled
    @State private var scheduleStartHour = SleepManager.shared.scheduleStartHour
    @State private var scheduleStartMinute = SleepManager.shared.scheduleStartMinute
    @State private var scheduleEndHour = SleepManager.shared.scheduleEndHour
    @State private var scheduleEndMinute = SleepManager.shared.scheduleEndMinute
    @State private var scheduleDays = SleepManager.shared.scheduleDays
    @State private var activityBasedEnabled = SleepManager.shared.activityBasedEnabled
    @State private var activityThresholdPercent = SleepManager.shared.activityThresholdPercent
    @State private var activityIdleTimeout = SleepManager.shared.activityIdleTimeoutSeconds
    @State private var networkBasedEnabled = SleepManager.shared.networkBasedEnabled
    @State private var watchedNetworks = SleepManager.shared.watchedNetworks
    @State private var newNetworkName = ""
    @State private var dimOnBatteryOnly = SleepManager.shared.dimOnBatteryOnly
    @State private var skipDimOnExternalDisplay = SleepManager.shared.skipDimOnExternalDisplay

    struct WatchedApp {
        let bundleID: String
        let name: String
    }

    var body: some View {
        Form {
            Section("General") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        if newValue {
                            try? SMAppService.mainApp.register()
                        } else {
                            try? SMAppService.mainApp.unregister()
                        }
                    }

                Toggle("Auto-deactivate when device sleeps", isOn: $autoDeactivate)
                    .onChange(of: autoDeactivate) { _, newValue in
                        SleepManager.shared.autoDeactivateOnSleep = newValue
                    }

                Toggle("Use caffeinate (no sudo required)", isOn: $useCaffeinate)
                    .onChange(of: useCaffeinate) { _, newValue in
                        SleepManager.shared.useCaffeinate = newValue
                        // If sleep is currently active, re-apply under the new mechanism
                        if SleepManager.shared.isSleepDisabled {
                            Task { @MainActor in
                                await SleepManager.shared.setSleepDisabled(false)
                                if let dur = SleepManager.shared.remainingTime {
                                    SleepManager.shared.enableSleep(duration: dur)
                                } else {
                                    SleepManager.shared.enableSleep(duration: nil)
                                }
                            }
                        }
                    }
                Text("Caffeinate mode prevents idle sleep only. It does not keep your Mac awake when the lid is closed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Only while on AC power", isOn: $requireCharging)
                    .onChange(of: requireCharging) { _, newValue in
                        SleepManager.shared.requireCharging = newValue
                    }
                Text("Sleep prevention will be disabled automatically if you unplug your Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Schedule") {
                Toggle("Enable on schedule", isOn: $scheduleEnabled)
                    .onChange(of: scheduleEnabled) { _, newValue in
                        SleepManager.shared.scheduleEnabled = newValue
                    }

                if scheduleEnabled {
                    HStack {
                        Text("From")
                        DatePicker(
                            "",
                            selection: Binding(
                                get: { TimeUtils.dateFrom(hour: scheduleStartHour, minute: scheduleStartMinute) },
                                set: { newDate in
                                    let comps = Calendar.current.dateComponents([.hour, .minute], from: newDate)
                                    scheduleStartHour = comps.hour ?? 9
                                    scheduleStartMinute = comps.minute ?? 0
                                    SleepManager.shared.scheduleStartHour = scheduleStartHour
                                    SleepManager.shared.scheduleStartMinute = scheduleStartMinute
                                }
                            ),
                            displayedComponents: .hourAndMinute
                        )
                        .labelsHidden()
                        Text("to")
                        DatePicker(
                            "",
                            selection: Binding(
                                get: { TimeUtils.dateFrom(hour: scheduleEndHour, minute: scheduleEndMinute) },
                                set: { newDate in
                                    let comps = Calendar.current.dateComponents([.hour, .minute], from: newDate)
                                    scheduleEndHour = comps.hour ?? 17
                                    scheduleEndMinute = comps.minute ?? 0
                                    SleepManager.shared.scheduleEndHour = scheduleEndHour
                                    SleepManager.shared.scheduleEndMinute = scheduleEndMinute
                                }
                            ),
                            displayedComponents: .hourAndMinute
                        )
                        .labelsHidden()
                    }

                    Text("Days")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        ForEach(1...7, id: \.self) { weekday in
                            let dayIndex = weekday - 1  // 0=Sun, 1=Mon, ..., 6=Sat
                            DayToggle(
                                label: TimeUtils.dayLabel(dayIndex),
                                weekday: weekday,
                                isOn: scheduleDays.contains(weekday)
                            ) { isOn in
                                if isOn {
                                    scheduleDays.insert(weekday)
                                } else {
                                    scheduleDays.remove(weekday)
                                }
                                SleepManager.shared.scheduleDays = scheduleDays
                            }
                        }
                    }
                }
            }

            Section("Triggers") {
                Text("Keep awake automatically when these apps are running.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(watchedApps, id: \.bundleID) { app in
                    HStack {
                        Image(systemName: "app.fill")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading) {
                            Text(app.name)
                            Text(app.bundleID)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                        Button {
                            removeWatchedApp(app.bundleID)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.borderless)
                    }
                }

                Button("Add App\u{2026}") {
                    addWatchedApp()
                }
            }

            Section("Activity-Based") {
                Toggle("Keep awake when active", isOn: $activityBasedEnabled)
                    .onChange(of: activityBasedEnabled) { _, newValue in
                        SleepManager.shared.activityBasedEnabled = newValue
                        SleepManager.shared.startActivityMonitor()
                    }

                if activityBasedEnabled {
                    HStack {
                        Text("CPU threshold")
                        Slider(value: Binding(
                            get: { Double(activityThresholdPercent) },
                            set: { activityThresholdPercent = Int($0); SleepManager.shared.activityThresholdPercent = activityThresholdPercent }
                        ), in: 5...95, step: 5)
                        Text("\(activityThresholdPercent)%")
                            .frame(width: 40)
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Text("Idle timeout")
                        Picker("", selection: $activityIdleTimeout) {
                            Text("30 sec").tag(30)
                            Text("1 min").tag(60)
                            Text("2 min").tag(120)
                            Text("5 min").tag(300)
                        }
                        .labelsHidden()
                        .frame(width: 100)
                        .onChange(of: activityIdleTimeout) { _, newValue in
                            SleepManager.shared.activityIdleTimeoutSeconds = newValue
                        }
                    }
                }
                Text("Insomniac will keep your Mac awake when CPU usage exceeds the threshold or the system has been active recently, and let it sleep when idle.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Network") {
                Toggle("Keep awake on selected Wi-Fi networks", isOn: $networkBasedEnabled)
                    .onChange(of: networkBasedEnabled) { _, newValue in
                        SleepManager.shared.networkBasedEnabled = newValue
                        SleepManager.shared.startNetworkMonitor()
                    }

                if networkBasedEnabled {
                    HStack {
                        TextField("Network name (SSID)", text: $newNetworkName)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(addNetwork)
                        Button("Add") { addNetwork() }
                            .disabled(newNetworkName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }

                    if !watchedNetworks.isEmpty {
                        ForEach(watchedNetworks, id: \.self) { network in
                            HStack {
                                Image(systemName: "wifi")
                                    .foregroundStyle(.secondary)
                                Text(network)
                                Spacer()
                                Button {
                                    removeNetwork(network)
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                Text("Insomniac will keep your Mac awake only when connected to one of these networks. No location permission is required.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Power Events") {
                Toggle("Dim screen only on battery", isOn: $dimOnBatteryOnly)
                    .onChange(of: dimOnBatteryOnly) { _, newValue in
                        SleepManager.shared.dimOnBatteryOnly = newValue
                    }
                Toggle("Skip dimming when external display connected", isOn: $skipDimOnExternalDisplay)
                    .onChange(of: skipDimOnExternalDisplay) { _, newValue in
                        SleepManager.shared.skipDimOnExternalDisplay = newValue
                    }
                Text("When the lid closes, Insomniac dims the built-in display after 5 seconds. These options add an extra gate before dimming.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Default Duration") {
                Picker("When enabling via shortcut", selection: $defaultDuration) {
                    Text("Indefinitely").tag(SleepManager.DurationOption.indefinite)
                    ForEach(SleepManager.DurationOption.presets) { option in
                        Text(option.title).tag(option)
                    }
                }
                .onChange(of: defaultDuration) { _, newValue in
                    SleepManager.shared.defaultDuration = newValue.seconds
                }
                Text("Left-clicking the menu bar icon or using the keyboard shortcut will enable sleep prevention for this duration.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Keyboard Shortcut") {
                KeyboardShortcuts.Recorder("Toggle shortcut:", name: .toggleSleep)
                Text("Default: \u{2318}\u{2325}I")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Text("Version")
                    Spacer()
                    Text(versionString())
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 12) {
                    Button("Export Settings\u{2026}") {
                        SettingsIO.exportSettings()
                    }
                    Button("Import Settings\u{2026}") {
                        SettingsIO.importSettings()
                    }
                }
            }
        }
        .padding(20)
        .frame(minWidth: 420)
        .onAppear {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            autoDeactivate = SleepManager.shared.autoDeactivateOnSleep
            useCaffeinate = SleepManager.shared.useCaffeinate
            requireCharging = SleepManager.shared.requireCharging
            defaultDuration = Self.currentDefaultOption()
            loadWatchedApps()
            activityBasedEnabled = SleepManager.shared.activityBasedEnabled
            activityThresholdPercent = SleepManager.shared.activityThresholdPercent
            activityIdleTimeout = SleepManager.shared.activityIdleTimeoutSeconds
            networkBasedEnabled = SleepManager.shared.networkBasedEnabled
            watchedNetworks = SleepManager.shared.watchedNetworks
            dimOnBatteryOnly = SleepManager.shared.dimOnBatteryOnly
            skipDimOnExternalDisplay = SleepManager.shared.skipDimOnExternalDisplay
        }
    }

    private func loadWatchedApps() {
        let bundleIDs = SleepManager.shared.watchedAppBundleIDs
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
        panel.title = "Choose an App"
        panel.message = "Select an app to watch. When this app is running, Insomniac will automatically prevent sleep."

        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let bundle = Bundle(url: url), let bundleID = bundle.bundleIdentifier else {
            showAlert(title: "Could not read app", message: "The selected file is not a valid app bundle.")
            return
        }

        var current = SleepManager.shared.watchedAppBundleIDs
        guard !current.contains(bundleID) else { return }
        current.append(bundleID)
        SleepManager.shared.watchedAppBundleIDs = current
        SleepManager.shared.updateWatchedApps()
        loadWatchedApps()
    }

    private func removeWatchedApp(_ bundleID: String) {
        var current = SleepManager.shared.watchedAppBundleIDs
        current.removeAll { $0 == bundleID }
        SleepManager.shared.watchedAppBundleIDs = current
        SleepManager.shared.updateWatchedApps()
        loadWatchedApps()
    }

    private func addNetwork() {
        let trimmed = newNetworkName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        var current = SleepManager.shared.watchedNetworks
        if !current.contains(trimmed) {
            current.append(trimmed)
            SleepManager.shared.watchedNetworks = current
            watchedNetworks = current
        }
        newNetworkName = ""
    }

    private func removeNetwork(_ ssid: String) {
        var current = SleepManager.shared.watchedNetworks
        current.removeAll { $0 == ssid }
        SleepManager.shared.watchedNetworks = current
        watchedNetworks = current
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func versionString() -> String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }

    private static func currentDefaultOption() -> SleepManager.DurationOption {
        let current = SleepManager.shared.defaultDuration
        if let current,
           let match = SleepManager.DurationOption.presets.first(where: { $0.seconds == current }) {
            return match
        }
        return .indefinite
    }
}

struct DayToggle: View {
    let label: String
    let weekday: Int
    let isOn: Bool
    let onToggle: (Bool) -> Void

    var body: some View {
        Button {
            onToggle(!isOn)
        } label: {
            Text(label)
                .font(.caption)
                .frame(width: 28, height: 22)
                .background(isOn ? Color.accentColor : Color.gray.opacity(0.2))
                .foregroundColor(isOn ? .white : .primary)
                .cornerRadius(4)
        }
        .buttonStyle(.borderless)
    }
}

enum TimeUtils {
    static func dateFrom(hour: Int, minute: Int) -> Date {
        var components = DateComponents()
        components.hour = hour
        components.minute = minute
        return Calendar.current.date(from: components) ?? Date()
    }

    static func dayLabel(_ index: Int) -> String {
        // 0=Sun, 1=Mon, ..., 6=Sat
        ["S", "M", "T", "W", "T", "F", "S"][index]
    }
}

#Preview {
    SettingsView()
}
