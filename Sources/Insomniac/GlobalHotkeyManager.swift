import Cocoa
import Carbon

final class GlobalHotkeyManager {
    static let shared = GlobalHotkeyManager()
    var onHotKeyPressed: (() -> Void)?
    
    private init() {}
    
    func registerHotkey() {
        var hotKeyRef: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: 12345, id: 1)
        
        let keyCode = UInt32(kVK_ANSI_T)
        let modifiers = UInt32(cmdKey | shiftKey)
        
        RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
        
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        
        InstallEventHandler(GetApplicationEventTarget(), { (nextHandler, theEvent, userData) -> OSStatus in
            GlobalHotkeyManager.shared.onHotKeyPressed?()
            return noErr
        }, 1, &eventType, nil, nil)
    }
}
