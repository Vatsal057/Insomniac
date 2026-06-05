import Foundation
import IOKit
import AppKit
import CoreGraphics

/// Monitors user activity (keyboard/mouse) and system CPU usage.
final class ActivityMonitor {
    static let shared = ActivityMonitor()

    private init() {}

    /// Returns the idle time in seconds (time since last user input).
    var systemIdleTime: TimeInterval {
        return CGEventSource.secondsSinceLastEventType(
            .combinedSessionState,
            eventType: .mouseMoved
        )
    }

    /// Returns current CPU usage as a percentage (0-100).
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

        var totalUser: UInt32 = 0
        var totalSystem: UInt32 = 0
        var totalNice: UInt32 = 0
        var totalIdle: UInt32 = 0

        for i in 0..<Int(processorCount) {
            let offset = Int(CPU_STATE_MAX) * i
            totalUser += UInt32(infoArray[offset + Int(CPU_STATE_USER)])
            totalSystem += UInt32(infoArray[offset + Int(CPU_STATE_SYSTEM)])
            totalNice += UInt32(infoArray[offset + Int(CPU_STATE_NICE)])
            totalIdle += UInt32(infoArray[offset + Int(CPU_STATE_IDLE)])
        }

        let total = totalUser + totalSystem + totalNice + totalIdle
        guard total > 0 else { return 0 }
        let active = total - totalIdle
        return Double(active) / Double(total) * 100.0
    }
}
