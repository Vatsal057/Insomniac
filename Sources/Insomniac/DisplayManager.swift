import Foundation
import CoreGraphics
import IOKit

@_silgen_name("DisplayServicesSetBrightness")
func DisplayServicesSetBrightness(_ display: CGDirectDisplayID, _ brightness: Float) -> Int32

@_silgen_name("DisplayServicesGetBrightness")
func DisplayServicesGetBrightness(_ display: CGDirectDisplayID, _ brightness: UnsafeMutablePointer<Float>) -> Int32

class DisplayManager {
    static let shared = DisplayManager()
    
    private var originalBrightness: Float?
    private var isCurrentlyDimmed = false
    
    private init() {}
    
    func isLidClosed() -> Bool {
        var iterator: io_iterator_t = 0
        let matchingDict = IOServiceMatching("IOPMrootDomain")
        
        let result = IOServiceGetMatchingServices(kIOMainPortDefault, matchingDict, &iterator)
        if result == kIOReturnSuccess {
            var service: io_registry_entry_t = 1
            while service != 0 {
                service = IOIteratorNext(iterator)
                if service != 0 {
                    if let property = IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool {
                        IOObjectRelease(service)
                        IOObjectRelease(iterator)
                        return property
                    }
                    IOObjectRelease(service)
                }
            }
            IOObjectRelease(iterator)
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
            DisplayServicesSetBrightness(displayId, 0.0)
            isCurrentlyDimmed = true
        }
    }
    
    func restoreScreen() {
        guard isCurrentlyDimmed, let brightness = originalBrightness else { return }
        
        let displayId = CGMainDisplayID()
        DisplayServicesSetBrightness(displayId, brightness)
        isCurrentlyDimmed = false
        originalBrightness = nil
    }
}
