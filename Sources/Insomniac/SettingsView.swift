import SwiftUI
import KeyboardShortcuts

struct SettingsView: View {
    var body: some View {
        Form {
            KeyboardShortcuts.Recorder("Toggle Shortcut:", name: .toggleSleep)
        }
        .padding(20)
        .frame(width: 350)
    }
}

#Preview {
    SettingsView()
}
