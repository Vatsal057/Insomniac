import Foundation
import IOKit.ps

/// Monitors Mac power state (battery vs AC power) via IOKit Power Sources.
final class PowerMonitor {
    static let shared = PowerMonitor()

    private var runLoopSource: Unmanaged<CFRunLoopSource>?

    private init() {}

    /// Returns true if the Mac is currently connected to AC power.
    var isOnACPower: Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
            return true // Assume AC if we can't determine
        }
        guard let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else {
            return true
        }

        for ps in sources {
            guard let desc = IOPSGetPowerSourceDescription(snapshot, ps)?.takeUnretainedValue() as? [String: Any] else {
                continue
            }
            if let state = desc[kIOPSPowerSourceStateKey] as? String {
                if state == kIOPSACPowerValue {
                    return true
                }
            }
        }
        return false
    }

    /// Current internal-battery charge percent (0–100), or nil on desktops /
    /// when unavailable.
    var batteryPercent: Int? {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else {
            return nil
        }
        for ps in sources {
            guard let desc = IOPSGetPowerSourceDescription(snapshot, ps)?.takeUnretainedValue() as? [String: Any] else {
                continue
            }
            if desc[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
               let current = desc[kIOPSCurrentCapacityKey] as? Int,
               let max = desc[kIOPSMaxCapacityKey] as? Int, max > 0 {
                return Int((Double(current) / Double(max)) * 100.0)
            }
        }
        return nil
    }

    /// Start observing power state changes. Calls `onChange` on the main queue.
    func start(onChange: @escaping (Bool) -> Void) {
        stop()

        let context = PowerCallbackContext(callback: onChange)
        let opaque = Unmanaged.passRetained(context).toOpaque()

        let callback: IOPowerSourceCallbackType = { ctx in
            guard let ctx else { return }
            let context = Unmanaged<PowerCallbackContext>.fromOpaque(ctx).takeUnretainedValue()
            let onAC = PowerMonitor.shared.isOnACPower
            DispatchQueue.main.async {
                context.callback(onAC)
            }
        }

        guard let source = IOPSNotificationCreateRunLoopSource(callback, opaque)?.takeRetainedValue() else {
            Unmanaged<PowerCallbackContext>.fromOpaque(opaque).release()
            return
        }

        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        runLoopSource = Unmanaged.passRetained(source)
    }

    func stop() {
        if let source = runLoopSource?.takeRetainedValue() {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
        }
        runLoopSource = nil
    }

    deinit {
        stop()
    }

    private final class PowerCallbackContext {
        let callback: (Bool) -> Void
        init(callback: @escaping (Bool) -> Void) {
            self.callback = callback
        }
    }
}
