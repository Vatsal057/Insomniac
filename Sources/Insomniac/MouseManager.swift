import Foundation
import CoreGraphics
import AppKit
import ApplicationServices
import OSLog
import UserNotifications

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

    private var defaultsObservations: [NSKeyValueObservation] = []

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
    private var hasWarnedAboutAccessibility = false

    /// `CGEvent.post` is silently dropped without Accessibility access, so
    /// without this the jiggler looks enabled and simply never does anything.
    /// Warn once per launch rather than on every tick.
    private func warnIfNotTrusted() {
        guard !AXIsProcessTrusted(), !hasWarnedAboutAccessibility else { return }
        hasWarnedAboutAccessibility = true
        logger.error("Accessibility access not granted — synthetic mouse events will be ignored.")

        let content = UNMutableNotificationContent()
        content.title = "Cursor Tools Need Accessibility"
        content.body = "Grant Insomniac Accessibility access in System Settings › Privacy & Security, or the jiggler and clicker won't move the cursor."
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        )
    }

    private func start() {
        timer?.invalidate()

        logger.info("Starting mouse activity timer (action interval: \(self.interval)s)")

        if activity == nil {
            // `.latencyCritical` disables timer coalescing and pins the CPU to a
            // high-performance state. This does a few CGEvent posts a minute —
            // `.userInitiated` is enough to stay scheduled, without the drain.
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated],
                reason: "Mouse Jiggler/Clicker Active"
            )
        }

        warnIfNotTrusted()

        Task { @MainActor in
            await self.evaluateAndPerformAction()
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

    private func scheduleNextCheck(after delay: TimeInterval) {
        timer?.invalidate()
        let clampedDelay = max(1.0, delay)
        timer = Timer.scheduledTimer(withTimeInterval: clampedDelay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                await self?.evaluateAndPerformAction()
            }
        }
    }

    func evaluateAndPerformAction() async {
        guard SleepManager.shared.isSleepDisabled else {
            stop()
            return
        }

        let now = Date()
        var nextCheckDelay: TimeInterval = interval

        if onlyWhenIdle {
            let idle = ActivityMonitor.shared.systemIdleTime
            if idle < inactivityDelay {
                nextCheckDelay = max(1.0, inactivityDelay - idle)
                scheduleNextCheck(after: nextCheckDelay)
                return
            }
        }

        let elapsed = now.timeIntervalSince(lastActionTime)
        if elapsed >= interval {
            lastActionTime = now
            await performAction()
            nextCheckDelay = interval
        } else {
            nextCheckDelay = interval - elapsed
        }

        scheduleNextCheck(after: nextCheckDelay)
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

            // Post at the HID level only. An event posted there already flows
            // down through the session tap to every app, so posting to both
            // delivers the same movement twice.
            let moveEvent = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)
            moveEvent?.post(tap: .cghidEventTap)

            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }

    /// Posts one down/up pair at the HID tap.
    ///
    /// Only `.cghidEventTap` — an event posted there is already delivered to
    /// every app via the session tap, so posting to both taps turns one click
    /// into two (and the double-click case into four).
    private func postClickPair(
        down: CGEventType,
        up: CGEventType,
        button: CGMouseButton,
        at target: CGPoint,
        clickState: Int64? = nil
    ) {
        for type in [down, up] {
            guard let event = CGEvent(
                mouseEventSource: nil,
                mouseType: type,
                mouseCursorPosition: target,
                mouseButton: button
            ) else { continue }
            if let clickState {
                event.setIntegerValueField(.mouseEventClickState, value: clickState)
            }
            event.post(tap: .cghidEventTap)
        }
    }

    private func postClick(at target: CGPoint) {
        switch clickType {
        case "left":
            postClickPair(down: .leftMouseDown, up: .leftMouseUp, button: .left, at: target)

        case "right":
            postClickPair(down: .rightMouseDown, up: .rightMouseUp, button: .right, at: target)

        case "middle":
            postClickPair(down: .otherMouseDown, up: .otherMouseUp, button: .center, at: target)

        case "double":
            postClickPair(down: .leftMouseDown, up: .leftMouseUp, button: .left, at: target, clickState: 1)
            postClickPair(down: .leftMouseDown, up: .leftMouseUp, button: .left, at: target, clickState: 2)

        default:
            break
        }
    }
}
