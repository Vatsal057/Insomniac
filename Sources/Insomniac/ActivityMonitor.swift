import Foundation
import AppKit
import CoreGraphics

/// Reads how long the user has been idle.
///
/// This used to also sample system-wide CPU load on a 30-second timer for the
/// activity trigger. That trigger is gone: there's no notification for "CPU
/// crossed a threshold", so it could only be done by polling, which meant the
/// app burned CPU continuously to measure CPU.
///
/// What's left is pull-only. Nothing here runs unless something asks, and the
/// only caller is the optional cursor jiggler, which asks while it's already
/// awake doing work.
@MainActor
final class ActivityMonitor {
    static let shared = ActivityMonitor()

    private init() {}

    /// Seconds since the last user input — mouse movement, click, key, or
    /// scroll, whichever is most recent.
    ///
    /// `CGEventSource` keeps these counters itself, so reading them is just a
    /// lookup; there's no sampling loop behind it.
    var systemIdleTime: TimeInterval {
        let inputTypes: [CGEventType] = [
            .mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown,
            .leftMouseDragged, .rightMouseDragged, .keyDown, .scrollWheel
        ]
        let idle = inputTypes
            .map { CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) }
            .min() ?? 0.0
        return idle >= 0 ? idle : 0.0
    }
}
