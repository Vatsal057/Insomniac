import SwiftUI
import KeyboardShortcuts
import ServiceManagement

struct SettingsView: View {
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var autoDeactivate = SleepManager.shared.autoDeactivateOnSleep
    @State private var useCaffeinate = SleepManager.shared.useCaffeinate
    @State private var defaultDuration: SleepManager.DurationOption = currentDefaultOption()

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
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            autoDeactivate = SleepManager.shared.autoDeactivateOnSleep
            useCaffeinate = SleepManager.shared.useCaffeinate
            defaultDuration = Self.currentDefaultOption()
        }
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
