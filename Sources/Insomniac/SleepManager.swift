import Foundation
import OSLog
import AppKit

@Observable @MainActor
final class SleepManager {
    static let shared = SleepManager()
    
    private let logger = Logger(subsystem: "com.insomniac.app", category: "SleepManager")
    
    private(set) var isSleepDisabled: Bool = false {
        didSet {
            if isSleepDisabled {
                startLidMonitor()
            } else {
                stopLidMonitor()
                DisplayManager.shared.restoreScreen()
            }
        }
    }
    
    private var lidMonitorTimer: Timer?
    private var lidClosedDuration: TimeInterval = 0.0
    
    private let batteryKey = "originalDisplaySleepBattery"
    private let acKey = "originalDisplaySleepAC"
    private var originalDisplaySleepBattery: Int?
    private var originalDisplaySleepAC: Int?
    
    private init() {
        originalDisplaySleepBattery = UserDefaults.standard.object(forKey: batteryKey) as? Int
        originalDisplaySleepAC = UserDefaults.standard.object(forKey: acKey) as? Int
        
        checkStatus()
        if isSleepDisabled {
            startLidMonitor()
        }
        
        setupTerminationObserver()
    }
    
    private func setupTerminationObserver() {
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                if self.isSleepDisabled {
                    self.setSleepDisabled(false)
                }
            }
        }
    }
    
    private func getDisplaySleepValues() -> (battery: Int?, ac: Int?) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g", "custom"]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                return parseDisplaySleep(from: output)
            }
        } catch {
            logger.error("Failed to get display sleep values: \(error.localizedDescription)")
        }
        return (nil, nil)
    }
    
    private func parseDisplaySleep(from output: String) -> (battery: Int?, ac: Int?) {
        var batteryValue: Int?
        var acValue: Int?
        
        let lines = output.components(separatedBy: .newlines)
        var currentSection: String?
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasSuffix("Power:") {
                currentSection = trimmed
            } else if trimmed.hasPrefix("displaysleep") {
                let parts = trimmed.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                if parts.count >= 2, let value = Int(parts[1]) {
                    if currentSection == "Battery Power:" {
                        batteryValue = value
                    } else if currentSection == "AC Power:" {
                        acValue = value
                    }
                }
            }
        }
        return (batteryValue, acValue)
    }
    
    private func setDisplaySleep(battery: Int?, ac: Int?) {
        if let battery = battery {
            runSudoPmset(args: ["-b", "displaysleep", String(battery)])
        }
        if let ac = ac {
            runSudoPmset(args: ["-c", "displaysleep", String(ac)])
        }
    }
    
    private func runSudoPmset(args: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        process.arguments = ["/usr/bin/pmset"] + args
        
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                logger.error("Failed to run sudo pmset \(args.joined(separator: " ")). Exit code: \(process.terminationStatus)")
            }
        } catch {
            logger.error("Failed to execute sudo pmset: \(error.localizedDescription)")
        }
    }
    
    private func startLidMonitor() {
        stopLidMonitor()
        lidClosedDuration = 0.0
        lidMonitorTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                
                if DisplayManager.shared.isLidClosed() {
                    self.lidClosedDuration += 1.0
                    if self.lidClosedDuration >= 5.0 {
                        DisplayManager.shared.dimScreen()
                    }
                } else {
                    self.lidClosedDuration = 0.0
                    DisplayManager.shared.restoreScreen()
                }
            }
        }
    }
    
    private func stopLidMonitor() {
        lidMonitorTimer?.invalidate()
        lidMonitorTimer = nil
        lidClosedDuration = 0.0
    }
    
    func toggleSleep() {
        let newState = !isSleepDisabled
        setSleepDisabled(newState)
    }
    
    func checkStatus() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g"]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                let lines = output.components(separatedBy: .newlines)
                var found = false
                for line in lines {
                    let lower = line.lowercased()
                    if lower.contains("sleepdisabled") || lower.contains("disablesleep") {
                        let parts = lower.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                        if parts.count >= 2 {
                            self.isSleepDisabled = (parts[1] == "1")
                            found = true
                            break
                        }
                    }
                }
                if !found {
                    // Fallback to searching the whole string if specific line parsing fails
                    let lowercased = output.lowercased()
                    self.isSleepDisabled = lowercased.contains("sleepdisabled 1") ||
                                           lowercased.contains("sleepdisabled\t1") ||
                                           lowercased.contains("disablesleep 1") ||
                                           lowercased.contains("disablesleep\t1")
                }
                logger.debug("Current sleep disabled status: \(self.isSleepDisabled)")
            }
        } catch {
            logger.error("Failed to check status: \(error.localizedDescription)")
        }
    }
    
    private func hasPermissions() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        process.arguments = ["-n", "/usr/bin/pmset", "-g"]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
    
    private func requestPermissions() -> Bool {
        let username = NSUserName()
        let scriptSource = """
        do shell script "mkdir -p /etc/sudoers.d && echo '\(username) ALL=(ALL) NOPASSWD: /usr/bin/pmset' > /etc/sudoers.d/insomniac && chmod 0440 /etc/sudoers.d/insomniac" with administrator privileges
        """
        
        var error: NSDictionary?
        if let script = NSAppleScript(source: scriptSource) {
            script.executeAndReturnError(&error)
            if let error = error {
                logger.error("AppleScript error: \(String(describing: error))")
                return false
            }
            return true
        }
        return false
    }
    
    private func setSleepDisabled(_ disabled: Bool) {
        if !hasPermissions() {
            if !requestPermissions() {
                logger.error("Failed to acquire required permissions.")
                return
            }
        }
        
        if disabled {
            let current = getDisplaySleepValues()
            if let battery = current.battery, originalDisplaySleepBattery == nil {
                originalDisplaySleepBattery = battery
                UserDefaults.standard.set(battery, forKey: batteryKey)
            }
            if let ac = current.ac, originalDisplaySleepAC == nil {
                originalDisplaySleepAC = ac
                UserDefaults.standard.set(ac, forKey: acKey)
            }
            runSudoPmset(args: ["-a", "displaysleep", "0"])
        } else {
            setDisplaySleep(battery: originalDisplaySleepBattery, ac: originalDisplaySleepAC)
            originalDisplaySleepBattery = nil
            originalDisplaySleepAC = nil
            UserDefaults.standard.removeObject(forKey: batteryKey)
            UserDefaults.standard.removeObject(forKey: acKey)
        }
        
        let value = disabled ? "1" : "0"
        runSudoPmset(args: ["-a", "disablesleep", value])
        
        // Update state regardless of return code for now, or we can check status again
        checkStatus()
    }
}
