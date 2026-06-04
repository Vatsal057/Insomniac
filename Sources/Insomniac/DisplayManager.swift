import Foundation
import CoreGraphics
import IOKit

@_silgen_name("DisplayServicesSetBrightness")
func DisplayServicesSetBrightness(_ display: CGDirectDisplayID, _ brightness: Float) -> Int32

@_silgen_name("DisplayServicesGetBrightness")
func DisplayServicesGetBrightness(_ display: CGDirectDisplayID, _ brightness: UnsafeMutablePointer<Float>) -> Int32

@MainActor
class DisplayManager {
    static let shared = DisplayManager()

    private var rootDomain: io_service_t = 0
    private var originalBrightness: Float?
    private var isCurrentlyDimmed = false

    private init() {
        rootDomain = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
    }

    deinit {
        if rootDomain != 0 {
            IOObjectRelease(rootDomain)
        }
    }

    func isLidClosed() -> Bool {
        guard rootDomain != 0 else { return false }

        if let property = IORegistryEntryCreateCFProperty(
            rootDomain,
            "AppleClamshellState" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? Bool {
            return property
        }
        return false
    }

    func dimScreen() {
        guard !isCurrentlyDimmed else { return }

        let displayId = CGMainDisplayID()
        var currentBrightness: Float = 0.0
        let result = DisplayServicesGetBrightness(displayId, &currentBrightness)

        if result == 0 {
            originalBrightness = currentBrightness
            _ = DisplayServicesSetBrightness(displayId, 0.0)
            isCurrentlyDimmed = true
        }
    }

    func restoreScreen() {
        guard isCurrentlyDimmed, let brightness = originalBrightness else { return }

        let displayId = CGMainDisplayID()
        _ = DisplayServicesSetBrightness(displayId, brightness)
        isCurrentlyDimmed = false
        originalBrightness = nil
    }
}
