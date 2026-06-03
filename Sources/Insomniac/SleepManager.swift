import Foundation
import OSLog
import AppKit
import IOKit

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

    // IOKit lid-close notification
    private var notifyPort: IONotificationPortRef?
    private var lidNotification: io_object_t = 0
    private var dimTask: Task<Void, Never>?

    private let batteryKey = "originalDisplaySleepBattery"
    private let acKey = "originalDisplaySleepAC"
    private var originalDisplaySleepBattery: Int?
    private var originalDisplaySleepAC: Int?

    private init() {
        originalDisplaySleepBattery = UserDefaults.standard.object(forKey: batteryKey) as? Int
        originalDisplaySleepAC = UserDefaults.standard.object(forKey: acKey) as? Int

        setupTerminationObserver()

        // Kick off status check off the main thread so init doesn't block
        Task { await self.checkStatus() }
    }

    private func setupTerminationObserver() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.isSleepDisabled {
                    self.setSleepDisabled(false)
                }
            }
        }
    }

    // MARK: - Lid monitor via IOKit notifications (replaces 1-second Timer poll)

    private func startLidMonitor() {
        stopLidMonitor()

        notifyPort = IONotificationPortCreate(kIOMainPortDefault)
        guard let port = notifyPort else { return }

        IONotificationPortSetDispatchQueue(port, DispatchQueue.main)

        guard let matchingDict = IOServiceMatching("IOPMrootDomain") else { return }

        // Retain the dict for the second call below
        let matchingDict2 = matchingDict  // CF bridging; both calls consume a ref
        _ = matchingDict2 // suppress unused warning — we pass it directly below

        let selfPtr = Unmanaged.passRetained(self).toOpaque()

        // We register on kIOGeneralInterest — IOPMrootDomain posts
        // kIOPMMessageClamshellStateChange among other power events.
        var service = IOServiceGetMatchingService(kIOMainPortDefault, matchingDict)
        guard service != 0 else {
            IONotificationPortDestroy(port)
            notifyPort = nil
            return
        }
        defer { IOObjectRelease(service) }

        let kr = IOServiceAddInterestNotification(
            port,
            service,
            kIOGeneralInterest,
            { refcon, _, messageType, _ in
                guard let refcon else { return }
                let manager = Unmanaged<SleepManager>.fromOpaque(refcon).takeUnretainedValue()
                // Any power message: re-evaluate lid state on main actor
                Task { @MainActor in
                    manager.handleLidStateChange()
                }
            },
            selfPtr,
            &lidNotification
        )

        if kr != kIOReturnSuccess {
            logger.error("IOServiceAddInterestNotification failed: \(kr)")
            IONotificationPortDestroy(port)
            notifyPort = nil
            // Release the retained self we passed as refcon since callback won't fire
            Unmanaged<SleepManager>.fromOpaque(selfPtr).release()
        }
    }

    private func stopLidMonitor() {
        if lidNotification != 0 {
            IOObjectRelease(lidNotification)
            lidNotification = 0
        }
        if let port = notifyPort {
            IONotificationPortDestroy(port)
            notifyPort = nil
        }
    }

    private func handleLidStateChange() {
        dimTask?.cancel()
        dimTask = nil

        if DisplayManager.shared.isLidClosed() {
            dimTask = Task {
                try? await Task.sleep(nanoseconds: 5 * 1_000_000_000)
                guard !Task.isCancelled else { return }
                DisplayManager.shared.dimScreen()
            }
        } else {
            DisplayManager.shared.restoreScreen()
        }
    }

    // MARK: - Toggle

    func toggleSleep() {
        setSleepDisabled(!isSleepDisabled)
    }

    // MARK: - Status check (async — does not block main thread)

    func checkStatus() async {
        let result = await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
            process.arguments = ["-g"]

            let pipe = Pipe()
            process.standardOutput = pipe

            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                return String(data: data, encoding: .utf8)
            } catch {
                return nil as String?
            }
        }.value

        guard let output = result else { return }

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
            let lowercased = output.lowercased()
            self.isSleepDisabled = lowercased.contains("sleepdisabled 1")
                || lowercased.contains("sleepdisabled\t1")
                || lowercased.contains("disablesleep 1")
                || lowercased.contains("disablesleep\t1")
        }
        logger.debug("Current sleep disabled status: \(self.isSleepDisabled)")
    }

    // MARK: - pmset helpers (kept — sudo pmset is the chosen mechanism per project decision)

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
        if let battery { runSudoPmset(args: ["-b", "displaysleep", String(battery)]) }
        if let ac     { runSudoPmset(args: ["-c", "displaysleep", String(ac)]) }
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
            if let error {
                logger.error("AppleScript error: \(String(describing: error))")
                return false
            }
            return true
        }
        return false
    }

    private func setSleepDisabled(_ disabled: Bool) {
        if !hasPermissions() {
            guard requestPermissions() else {
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

        // Set state directly — we know what we just applied; no need to re-parse pmset output
        isSleepDisabled = disabled
    }
}
