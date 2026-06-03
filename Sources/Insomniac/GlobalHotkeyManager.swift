import Cocoa
import KeyboardShortcuts

/// Manages global hotkey registration using the KeyboardShortcuts library.
final class GlobalHotkeyManager {
    static let shared = GlobalHotkeyManager()
    var onHotKeyPressed: (() -> Void)?

    private init() {}

    func registerHotkey() {
        KeyboardShortcuts.onKeyDown(for: .toggleSleep) { [weak self] in
            self?.onHotKeyPressed?()
        }
    }
}
