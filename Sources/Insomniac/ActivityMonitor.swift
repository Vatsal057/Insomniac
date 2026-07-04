import Foundation
import IOKit
import AppKit
import CoreGraphics

/// Monitors user activity (keyboard/mouse) and system CPU usage.
@MainActor
final class ActivityMonitor {
    static let shared = ActivityMonitor()

    private init() {}

    /// Returns the idle time in seconds (time since last user input —
    /// mouse movement OR keyboard activity, whichever is more recent).
    /// Note: CGEventType has no "any input" case in Swift, so take the
    /// minimum across the input event types we care about.
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

    private var previousActiveTicks: UInt64 = 0
    private var previousIdleTicks: UInt64 = 0

    /// Returns current CPU usage as a percentage (0-100), measured as the
    /// delta since the previous call (host_processor_info ticks are
    /// cumulative since boot). The first call returns the boot-average.
    var cpuUsagePercent: Double {
        var processorInfoArray: processor_info_array_t?
        var processorMsgCount: mach_msg_type_number_t = 0
        var processorCount: natural_t = 0

        let result = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &processorCount,
            &processorInfoArray,
            &processorMsgCount
        )

        guard result == KERN_SUCCESS, let infoArray = processorInfoArray else {
            return 0
        }

        defer {
            let size = Int(processorMsgCount) * MemoryLayout<integer_t>.stride
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: infoArray), vm_size_t(size))
        }

        var totalActive: UInt64 = 0
        var totalIdle: UInt64 = 0

        for i in 0..<Int(processorCount) {
            let offset = Int(CPU_STATE_MAX) * i
            totalActive += UInt64(UInt32(bitPattern: infoArray[offset + Int(CPU_STATE_USER)]))
            totalActive += UInt64(UInt32(bitPattern: infoArray[offset + Int(CPU_STATE_SYSTEM)]))
            totalActive += UInt64(UInt32(bitPattern: infoArray[offset + Int(CPU_STATE_NICE)]))
            totalIdle += UInt64(UInt32(bitPattern: infoArray[offset + Int(CPU_STATE_IDLE)]))
        }

        let total = totalActive + totalIdle
        let activeDelta = totalActive &- previousActiveTicks
        let totalDelta = total &- (previousActiveTicks + previousIdleTicks)
        previousActiveTicks = totalActive
        previousIdleTicks = totalIdle

        guard totalDelta > 0, activeDelta <= totalDelta else { return 0 }
        return Double(activeDelta) / Double(totalDelta) * 100.0
    }
}
