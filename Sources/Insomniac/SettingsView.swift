import SwiftUI
import KeyboardShortcuts
import ServiceManagement

struct SettingsView: View {
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

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
            }

            Section("Keyboard Shortcut") {
                KeyboardShortcuts.Recorder("Toggle shortcut:", name: .toggleSleep)
                Text("Default: \u{2318}\u{2325}I")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
                let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
                HStack {
                    Text("Version")
                    Spacer()
                    Text("\(version) (\(build))")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

#Preview {
    SettingsView()
}
