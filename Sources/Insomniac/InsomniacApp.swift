import SwiftUI
import ServiceManagement
import KeyboardShortcuts

@main
struct InsomniacApp: App {
    @State private var sleepManager = SleepManager.shared

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)

        // Set default shortcut to Cmd+Option+I (less likely to conflict than Cmd+Shift+T)
        // Only set if not already defined in UserDefaults
        if KeyboardShortcuts.getShortcut(for: .toggleSleep) == nil {
            KeyboardShortcuts.setShortcut(.init(.i, modifiers: [.command, .option]), for: .toggleSleep)
        }

        GlobalHotkeyManager.shared.onHotKeyPressed = {
            SleepManager.shared.toggleSleep()
        }
        GlobalHotkeyManager.shared.registerHotkey()

        // Register as a login item (macOS 13+). No-ops silently if already registered.
        try? SMAppService.mainApp.register()
    }

    var body: some Scene {
        MenuBarExtra {
            // Status label (non-interactive) so the state is unambiguous
            Text("Sleep Prevention: \(sleepManager.isSleepDisabled ? "ON" : "OFF")")
                .foregroundStyle(sleepManager.isSleepDisabled ? Color.orange : Color.secondary)

            Divider()

            Button(sleepManager.isSleepDisabled ? "Re-enable Sleep" : "Disable Sleep") {
                sleepManager.toggleSleep()
            }

            SettingsLink {
                Text("Settings...")
            }
            .keyboardShortcut(",", modifiers: [.command])

            Divider()

            Button("Quit Insomniac") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("Q", modifiers: [.command])
        } label: {
            Image(systemName: sleepManager.isSleepDisabled ? "sun.max.fill" : "moon.fill")
        }

        Settings {
            SettingsView()
        }
    }
}
