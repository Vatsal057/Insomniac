import SwiftUI
import ServiceManagement

@main
struct InsomniacApp: App {
    @State private var sleepManager = SleepManager.shared

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)

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
            .keyboardShortcut("T", modifiers: [.command, .shift])

            Divider()

            Button("Quit Insomniac") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("Q", modifiers: [.command])
        } label: {
            Image(systemName: sleepManager.isSleepDisabled ? "sun.max.fill" : "moon.fill")
        }
    }
}
