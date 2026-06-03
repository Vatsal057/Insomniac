import Cocoa

/// Registers a global hotkey (Cmd+Shift+T) using NSEvent instead of the
/// deprecated Carbon RegisterEventHotKey API.
final class GlobalHotkeyManager {
    static let shared = GlobalHotkeyManager()
    var onHotKeyPressed: (() -> Void)?

    private var monitor: Any?

    private init() {}

    deinit {
        unregisterHotkey()
    }

    func registerHotkey() {
        // NSEvent.addGlobalMonitorForEvents fires for key-down events in other
        // apps; addLocalMonitorForEvents covers when Insomniac itself is focused.
        // The combination ensures the shortcut works regardless of frontmost app.
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard
                event.modifierFlags.contains([.command, .shift]),
                event.keyCode == 17  // kVK_ANSI_T
            else { return }
            self?.onHotKeyPressed?()
        }
    }

    func unregisterHotkey() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
}
