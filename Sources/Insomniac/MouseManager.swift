import Foundation
import CoreGraphics
import AppKit
import OSLog

@Observable @MainActor
final class MouseManager {
    static let shared = MouseManager()
    private let logger = Logger(subsystem: "com.insomniac.app", category: "MouseManager")

    private var timer: Timer?

    // Settings Keys
    static let jigglerEnabledKey = "mouseJigglerEnabled"
    static let clickerEnabledKey = "mouseClickerEnabled"
    static let intervalKey = "mouseJigglerInterval"
    static let inactivityDelayKey = "mouseJigglerInactivityDelay"
    static let clickXKey = "mouseJigglerClickX"
    static let clickYKey = "mouseJigglerClickY"
    static let returnCursorKey = "mouseJigglerReturnCursor"
    static let onlyWhenIdleKey = "mouseJigglerOnlyWhenIdle"
    static let speedKey = "mouseJigglerSpeed"
    static let clickTypeKey = "mouseJigglerClickType"

    var isJigglerEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.jigglerEnabledKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.jigglerEnabledKey)
            updateTimerState()
        }
    }

    var isClickerEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.clickerEnabledKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.clickerEnabledKey)
            updateTimerState()
        }
    }

    var interval: TimeInterval {
        get {
            let val = UserDefaults.standard.double(forKey: Self.intervalKey)
            return val > 0 ? val : 60.0
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.intervalKey)
            updateTimerState()
        }
    }

    var inactivityDelay: TimeInterval {
        get {
            let val = UserDefaults.standard.double(forKey: Self.inactivityDelayKey)
            return val > 0 ? val : 30.0
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.inactivityDelayKey)
        }
    }

    var clickX: Double {
        get { UserDefaults.standard.double(forKey: Self.clickXKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.clickXKey) }
    }

    var clickY: Double {
        get { UserDefaults.standard.double(forKey: Self.clickYKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.clickYKey) }
    }

    var returnCursor: Bool {
        get { UserDefaults.standard.bool(forKey: Self.returnCursorKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.returnCursorKey) }
    }

    var onlyWhenIdle: Bool {
        get { UserDefaults.standard.bool(forKey: Self.onlyWhenIdleKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.onlyWhenIdleKey) }
    }

    var speed: Double {
        get {
            let val = UserDefaults.standard.double(forKey: Self.speedKey)
            return val > 0 ? val : 1.0
        }
        set { UserDefaults.standard.set(newValue, forKey: Self.speedKey) }
    }

    var clickType: String {
        get { UserDefaults.standard.string(forKey: Self.clickTypeKey) ?? "left" }
        set { UserDefaults.standard.set(newValue, forKey: Self.clickTypeKey) }
    }

    private init() {
        let defaults: [String: Any] = [
            Self.jigglerEnabledKey: false,
            Self.clickerEnabledKey: false,
            Self.intervalKey: 60.0,
            Self.inactivityDelayKey: 30.0,
            Self.clickXKey: 0.0,
            Self.clickYKey: 0.0,
            Self.returnCursorKey: true,
            Self.onlyWhenIdleKey: true,
            Self.speedKey: 1.0,
            Self.clickTypeKey: "left"
        ]
        UserDefaults.standard.register(defaults: defaults)

        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.updateTimerState()
            }
        }
    }

    /// The jiggler/clicker only runs while a sleep-prevention session is
    /// active. Called whenever the toggles or the sleep state change.
    func updateTimerState() {
        let shouldRun = (isJigglerEnabled || isClickerEnabled) && SleepManager.shared.isSleepDisabled
        if shouldRun {
            start()
        } else {
            stop()
        }
    }

    private var activity: NSObjectProtocol?
    private var lastActionTime: Date = Date.distantPast

    private func start() {
        timer?.invalidate()

        logger.info("Starting mouse activity timer (action interval: \(self.interval)s)")

        if activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .latencyCritical],
                reason: "Mouse Jiggler/Clicker Active"
            )
        }

        // Trigger evaluation once immediately
        Task { @MainActor in
            await self.evaluateAndPerformAction()
        }

        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.evaluateAndPerformAction()
            }
        }
    }

    func stop() {
        if timer != nil {
            logger.info("Stopping mouse activity timer")
            timer?.invalidate()
            timer = nil
        }

        if let activity = activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }

    func evaluateAndPerformAction() async {
        guard SleepManager.shared.isSleepDisabled else { return }

        // Idle Check
        if onlyWhenIdle {
            let idle = ActivityMonitor.shared.systemIdleTime
            guard idle >= inactivityDelay else {
                return // Not idle long enough
            }
        }

        let now = Date()
        if now.timeIntervalSince(lastActionTime) >= interval {
            lastActionTime = now
            await performAction()
        }
    }

    func performAction() async {
        guard let currentEvent = CGEvent(source: nil) else {
            logger.error("Failed to read current mouse location")
            return
        }
        let originalLocation = currentEvent.location

        // 1. Process Clicker if enabled. (0,0) means the user never picked a
        // target — skip rather than clicking the Apple menu corner.
        if isClickerEnabled && (clickX != 0 || clickY != 0) {
            let targetLocation = CGPoint(x: clickX, y: clickY)

            // Move to target using smooth Bezier path
            await moveMouseSmoothly(from: originalLocation, to: targetLocation, speed: speed)
            postClick(at: targetLocation)

            if returnCursor {
                try? await Task.sleep(nanoseconds: 100 * 1_000_000) // 100ms delay
                await moveMouseSmoothly(from: targetLocation, to: originalLocation, speed: speed)
            }
        }

        // 2. Process Jiggler if enabled
        if isJigglerEnabled {
            // Get current location (might have changed if clicker moved it and didn't return, or if user moved it)
            guard let updatedEvent = CGEvent(source: nil) else { return }
            let currentLocation = updatedEvent.location

            let dx = CGFloat.random(in: -30...30)
            let dy = CGFloat.random(in: -30...30)
            let newLocation = CGPoint(x: currentLocation.x + dx, y: currentLocation.y + dy)

            await moveMouseSmoothly(from: currentLocation, to: newLocation, speed: speed)
        }
    }

    private func moveMouseSmoothly(from start: CGPoint, to end: CGPoint, speed: Double) async {
        let steps = max(5, Int(12.0 / speed))
        let delay = 0.003 + (0.012 * (1.0 - speed))

        let distanceX = end.x - start.x
        let distanceY = end.y - start.y

        // Generate curved Bezier path
        let ctrl1 = CGPoint(
            x: start.x + distanceX * 0.25 + CGFloat.random(in: -20...20),
            y: start.y + distanceY * 0.25 + CGFloat.random(in: -20...20)
        )
        let ctrl2 = CGPoint(
            x: start.x + distanceX * 0.75 + CGFloat.random(in: -20...20),
            y: start.y + distanceY * 0.75 + CGFloat.random(in: -20...20)
        )

        for i in 1...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let mt = 1.0 - t

            let x = mt * mt * mt * start.x + 3 * mt * mt * t * ctrl1.x + 3 * mt * t * t * ctrl2.x + t * t * t * end.x
            let y = mt * mt * mt * start.y + 3 * mt * mt * t * ctrl1.y + 3 * mt * t * t * ctrl2.y + t * t * t * end.y
            let point = CGPoint(x: x, y: y)

            // Warp the cursor position on the screen (does not require accessibility permission)
            CGWarpMouseCursorPosition(point)

            // Also post a session event to notify OS of movement
            let moveEvent = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)
            moveEvent?.post(tap: .cgSessionEventTap)
            moveEvent?.post(tap: .cghidEventTap) // Also post to HID event tap to keep presence apps awake

            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }

    private func postClick(at target: CGPoint) {
        switch clickType {
        case "left":
            let clickDown = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: target, mouseButton: .left)
            clickDown?.post(tap: .cgSessionEventTap)
            clickDown?.post(tap: .cghidEventTap)
            let clickUp = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: target, mouseButton: .left)
            clickUp?.post(tap: .cgSessionEventTap)
            clickUp?.post(tap: .cghidEventTap)

        case "right":
            let clickDown = CGEvent(mouseEventSource: nil, mouseType: .rightMouseDown, mouseCursorPosition: target, mouseButton: .right)
            clickDown?.post(tap: .cgSessionEventTap)
            clickDown?.post(tap: .cghidEventTap)
            let clickUp = CGEvent(mouseEventSource: nil, mouseType: .rightMouseUp, mouseCursorPosition: target, mouseButton: .right)
            clickUp?.post(tap: .cgSessionEventTap)
            clickUp?.post(tap: .cghidEventTap)

        case "middle":
            let clickDown = CGEvent(mouseEventSource: nil, mouseType: .otherMouseDown, mouseCursorPosition: target, mouseButton: .center)
            clickDown?.post(tap: .cgSessionEventTap)
            clickDown?.post(tap: .cghidEventTap)
            let clickUp = CGEvent(mouseEventSource: nil, mouseType: .otherMouseUp, mouseCursorPosition: target, mouseButton: .center)
            clickUp?.post(tap: .cgSessionEventTap)
            clickUp?.post(tap: .cghidEventTap)

        case "double":
            let clickDown1 = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: target, mouseButton: .left)
            clickDown1?.setIntegerValueField(.mouseEventClickState, value: 1)
            clickDown1?.post(tap: .cgSessionEventTap)
            clickDown1?.post(tap: .cghidEventTap)

            let clickUp1 = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: target, mouseButton: .left)
            clickUp1?.setIntegerValueField(.mouseEventClickState, value: 1)
            clickUp1?.post(tap: .cgSessionEventTap)
            clickUp1?.post(tap: .cghidEventTap)

            let clickDown2 = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: target, mouseButton: .left)
            clickDown2?.setIntegerValueField(.mouseEventClickState, value: 2)
            clickDown2?.post(tap: .cgSessionEventTap)
            clickDown2?.post(tap: .cghidEventTap)

            let clickUp2 = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: target, mouseButton: .left)
            clickUp2?.setIntegerValueField(.mouseEventClickState, value: 2)
            clickUp2?.post(tap: .cgSessionEventTap)
            clickUp2?.post(tap: .cghidEventTap)

        default:
            break
        }
    }
}
