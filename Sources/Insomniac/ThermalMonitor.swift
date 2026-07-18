import Foundation

/// Watches the system thermal state and fires when the Mac gets hot.
///
/// Running with the lid closed under load can overheat the machine; this lets
/// `SleepManager` pause sleep prevention before that happens.
final class ThermalMonitor {
    static let shared = ThermalMonitor()

    private var observer: NSObjectProtocol?

    private init() {}

    var currentState: ProcessInfo.ThermalState {
        ProcessInfo.processInfo.thermalState
    }

    /// True when `state` reaches or exceeds the trip level.
    /// `critical == false` trips at `.serious`; `true` trips only at `.critical`.
    static func isHot(_ state: ProcessInfo.ThermalState, criticalOnly: Bool) -> Bool {
        let trip: ProcessInfo.ThermalState = criticalOnly ? .critical : .serious
        return state.rank >= trip.rank
    }

    /// Calls `onChange` on the main queue whenever the thermal state changes.
    func start(onChange: @escaping (ProcessInfo.ThermalState) -> Void) {
        stop()
        observer = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            onChange(ProcessInfo.processInfo.thermalState)
        }
    }

    func stop() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
    }
}

private extension ProcessInfo.ThermalState {
    /// Orderable severity (`.nominal` < `.fair` < `.serious` < `.critical`).
    var rank: Int {
        switch self {
        case .nominal: return 0
        case .fair: return 1
        case .serious: return 2
        case .critical: return 3
        @unknown default: return 0
        }
    }
}
