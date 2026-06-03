import SwiftUI

@main
struct InsomniacApp: App {
    @State private var sleepManager = SleepManager.shared
    
    init() {
        NSApplication.shared.setActivationPolicy(.accessory)
        
        GlobalHotkeyManager.shared.onHotKeyPressed = {
            SleepManager.shared.toggleSleep()
        }
        GlobalHotkeyManager.shared.registerHotkey()
    }
    
    var body: some Scene {
        MenuBarExtra {
            Button(sleepManager.isSleepDisabled ? "Enable Sleep" : "Disable Sleep") {
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
