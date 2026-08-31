import Foundation
import CoreGraphics
import IOKit
import OSLog

/// Runtime binding for the private DisplayServices brightness API.
///
/// Previously declared with `@_silgen_name` against a hard-linked private
/// framework, which makes a future macOS that renames or drops the symbol a
/// launch failure for the whole app. Resolving through `dlsym` turns the same
/// situation into "lid dimming is unavailable".
private enum DisplayServices {
    typealias SetBrightness = @convention(c) (CGDirectDisplayID, Float) -> Int32
    typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32

    // Deliberately not named `set`/`get`: those read as accessor keywords
    // inside a computed-property body.
    static let setBrightness: SetBrightness? = symbol("DisplayServicesSetBrightness")
    static let getBrightness: GetBrightness? = symbol("DisplayServicesGetBrightness")

    static var isAvailable: Bool { setBrightness != nil && getBrightness != nil }

    private static let handle: UnsafeMutableRawPointer? = dlopen(
        "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
        RTLD_LAZY | RTLD_LOCAL
    )

    private static func symbol<T>(_ name: String) -> T? {
        guard let handle, let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }
}

@MainActor
class DisplayManager {
    static let shared = DisplayManager()

    private let logger = Logger(subsystem: "com.insomniac.app", category: "DisplayManager")

    private var rootDomain: io_service_t = 0
    private var originalBrightness: Float?
    private var isCurrentlyDimmed = false

    private init() {
        rootDomain = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        if !DisplayServices.isAvailable {
            logger.notice("DisplayServices brightness API unavailable — lid dimming disabled.")
        }
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
        guard let getBrightness = DisplayServices.getBrightness,
              let setBrightness = DisplayServices.setBrightness else { return }

        let displayId = CGMainDisplayID()
        var currentBrightness: Float = 0.0
        let result = getBrightness(displayId, &currentBrightness)

        if result == 0 {
            originalBrightness = currentBrightness
            _ = setBrightness(displayId, 0.0)
            isCurrentlyDimmed = true
        }
    }

    func restoreScreen() {
        guard isCurrentlyDimmed, let brightness = originalBrightness else { return }
        guard let setBrightness = DisplayServices.setBrightness else { return }

        let displayId = CGMainDisplayID()
        _ = setBrightness(displayId, brightness)
        isCurrentlyDimmed = false
        originalBrightness = nil
    }
}
