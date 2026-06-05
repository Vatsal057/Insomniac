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
        .frame(width: 420)
        .onAppear {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            autoDeactivate = SleepManager.shared.autoDeactivateOnSleep
            useCaffeinate = SleepManager.shared.useCaffeinate
            requireCharging = SleepManager.shared.requireCharging
            defaultDuration = Self.currentDefaultOption()
            loadWatchedApps()
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

#Preview {
    SettingsView()
}
