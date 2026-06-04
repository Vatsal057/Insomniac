import SwiftUI
import KeyboardShortcuts
import ServiceManagement

struct SettingsView: View {
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var autoDeactivate = SleepManager.shared.autoDeactivateOnSleep
    @State private var showRemoveSudoAlert = false
    @State private var showSudoRemovedAlert = false

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
            }

            Section("Keyboard Shortcut") {
                KeyboardShortcuts.Recorder("Toggle shortcut:", name: .toggleSleep)
                Text("Default: \u{2318}\u{2325}I")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Permissions") {
                Button("Remove Sudo Permissions", role: .destructive) {
                    showRemoveSudoAlert = true
                }
                Text("Removes passwordless sudo access for pmset. You'll be prompted for your password next time.")
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
            autoDeactivate = SleepManager.shared.autoDeactivateOnSleep
        }
        .alert("Remove Sudo Permissions?", isPresented: $showRemoveSudoAlert) {
            Button("Remove", role: .destructive) {
                Task {
                    await SleepManager.shared.removePermissions()
                    showSudoRemovedAlert = true
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will remove the passwordless sudo entry for pmset. You'll be prompted for your password next time you toggle sleep prevention.")
        }
        .alert("Sudo Permissions Removed", isPresented: $showSudoRemovedAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The passwordless sudo entry has been removed.")
        }
    }
}

#Preview {
    SettingsView()
}
