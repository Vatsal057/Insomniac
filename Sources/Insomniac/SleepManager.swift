import Foundation
import OSLog
import AppKit
import IOKit
import UserNotifications

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

    nonisolated private let rootDomain: io_service_t
    private var _hasSudoPermissions: Bool?
    private var isToggling = false

    let autoDeactivateKey = "autoDeactivateOnSleep"
    var autoDeactivateOnSleep: Bool {
        get { UserDefaults.standard.bool(forKey: autoDeactivateKey) }
        set { UserDefaults.standard.set(newValue, forKey: autoDeactivateKey) }
    }

    private let firstLaunchKey = "hasLaunchedBefore"
    var isFirstLaunch: Bool { !UserDefaults.standard.bool(forKey: firstLaunchKey) }

    private var notifyPort: IONotificationPortRef?
    private var lidNotification: io_object_t = 0
    private var dimTask: Task<Void, any Error>?

    private let batteryKey = "originalDisplaySleepBattery"
    private let acKey = "originalDisplaySleepAC"
    private var originalDisplaySleepBattery: Int?
    private var originalDisplaySleepAC: Int?

    private let screensaverKey = "originalScreensaverDisabled"
    private var originalScreensaverDisabled: Bool?

    private init() {
        self.rootDomain = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))

        originalDisplaySleepBattery = UserDefaults.standard.object(forKey: batteryKey) as? Int
        originalDisplaySleepAC = UserDefaults.standard.object(forKey: acKey) as? Int
        originalScreensaverDisabled = UserDefaults.standard.object(forKey: screensaverKey) as? Bool

        setupTerminationObserver()
        setupSleepNotificationObserver()

        checkStatus()
    }

    deinit {
        if rootDomain != 0 {
            IOObjectRelease(rootDomain)
        }
    }

    func markFirstLaunchComplete() {
        UserDefaults.standard.set(true, forKey: firstLaunchKey)
    }

    // MARK: - Observers

    private func setupTerminationObserver() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.isSleepDisabled {
                    await self.setSleepDisabled(false)
                }
            }
        }
    }

    private func setupSleepNotificationObserver() {
        NotificationCenter.default.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.autoDeactivateOnSleep, self.isSleepDisabled else { return }
                await self.setSleepDisabled(false)
            }
        }
    }

    // MARK: - Notifications

    func requestNotificationPermission() {
        guard Bundle.main.bundlePath.hasSuffix(".app") else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: .alert) { _, _ in }
    }

    private func sendNotification(title: String, body: String) {
        guard Bundle.main.bundlePath.hasSuffix(".app") else { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = nil

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Screensaver control

    private func disableScreensaver() {
        let current = UserDefaults.standard.bool(forKey: "com.apple.screensaver.idleTime")
        if originalScreensaverDisabled == nil {
            originalScreensaverDisabled = current
            UserDefaults.standard.set(current, forKey: screensaverKey)
        }
        UserDefaults.standard.set(true, forKey: "com.apple.screensaver.idleTime")
        runDefaultsWrite(domain: "com.apple.screensaver", key: "idleTime", value: true)
    }

    private func restoreScreensaver() {
        if let original = originalScreensaverDisabled {
            UserDefaults.standard.set(original, forKey: "com.apple.screensaver.idleTime")
            runDefaultsWrite(domain: "com.apple.screensaver", key: "idleTime", value: original)
            originalScreensaverDisabled = nil
            UserDefaults.standard.removeObject(forKey: screensaverKey)
        }
    }

    private func runDefaultsWrite(domain: String, key: String, value: Bool) {
        Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
            process.arguments = ["write", domain, key, "-bool", value ? "true" : "false"]
            try? process.run()
            process.waitUntilExit()
        }
    }

    // MARK: - Lid monitor via IOKit notifications

    private func startLidMonitor() {
        stopLidMonitor()

        notifyPort = IONotificationPortCreate(kIOMainPortDefault)
        guard let port = notifyPort else { return }

        IONotificationPortSetDispatchQueue(port, DispatchQueue.main)

        guard rootDomain != 0 else { return }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        let kr = IOServiceAddInterestNotification(
            port,
            rootDomain,
            kIOGeneralInterest,
            { refcon, _, _, _ in
                guard let refcon else { return }
                let manager = Unmanaged<SleepManager>.fromOpaque(refcon).takeUnretainedValue()
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
        }
    }

    private func stopLidMonitor() {
        dimTask?.cancel()
        dimTask = nil

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
                do {
                    try await Task.sleep(nanoseconds: 5 * 1_000_000_000)
                    DisplayManager.shared.dimScreen()
                } catch is CancellationError {}
            }
        } else {
            DisplayManager.shared.restoreScreen()
        }
    }

    // MARK: - Toggle

    func toggleSleep() {
        guard !isToggling else { return }
        isToggling = true
        Task {
            let newState = !isSleepDisabled
            await setSleepDisabled(newState)
            isToggling = false

            let title = newState ? "Sleep Prevention Enabled" : "Sleep Prevention Disabled"
            let body = newState
                ? "Your Mac will stay awake even with the lid closed."
                : "Your Mac can now sleep normally."
            sendNotification(title: title, body: body)
        }
    }

    // MARK: - Status check

    func checkStatus() {
        guard rootDomain != 0 else { return }

        if let property = IORegistryEntryCreateCFProperty(
            rootDomain,
            "SleepDisabled" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? NSNumber {
            self.isSleepDisabled = property.boolValue
        } else {
            Task {
                await checkStatusViaPmset()
            }
        }
    }

    private func checkStatusViaPmset() async {
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
            } catch { return nil }
        }.value

        guard let output = result else { return }

        let lower = output.lowercased()
        if lower.contains("sleepdisabled 1") || lower.contains("sleepdisabled\t1") ||
           lower.contains("disablesleep 1") || lower.contains("disablesleep\t1") {
            self.isSleepDisabled = true
        } else {
            self.isSleepDisabled = false
        }
    }

    // MARK: - pmset helpers

    private func getDisplaySleepValues() async -> (battery: Int?, ac: Int?) {
        await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
            process.arguments = ["-g", "custom"]
            let pipe = Pipe()
            process.standardOutput = pipe
            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let output = String(data: data, encoding: .utf8) {
                    return SleepManager.parseDisplaySleepStatic(from: output)
                }
            } catch {}
            return (nil, nil)
        }.value
    }

    nonisolated private static func parseDisplaySleepStatic(from output: String) -> (battery: Int?, ac: Int?) {
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
                    if currentSection == "Battery Power:" { batteryValue = value }
                    else if currentSection == "AC Power:" { acValue = value }
                }
            }
        }
        return (batteryValue, acValue)
    }

    private func setDisplaySleep(battery: Int?, ac: Int?) async {
        if let battery { await runSudoPmset(args: ["-b", "displaysleep", String(battery)]) }
        if let ac     { await runSudoPmset(args: ["-c", "displaysleep", String(ac)]) }
    }

    @discardableResult
    private func runSudoPmset(args: [String]) async -> Bool {
        let success = await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            process.arguments = ["/usr/bin/pmset"] + args
            do {
                try process.run()
                process.waitUntilExit()
                return process.terminationStatus == 0
            } catch { return false }
        }.value

        if !success {
            _hasSudoPermissions = nil
        }
        return success
    }

    private func hasPermissions() async -> Bool {
        if let cached = _hasSudoPermissions { return cached }

        let result = await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            process.arguments = ["-n", "/usr/bin/pmset", "-g"]
            do {
                try process.run()
                process.waitUntilExit()
                return process.terminationStatus == 0
            } catch { return false }
        }.value

        _hasSudoPermissions = result
        return result
    }

    private func requestPermissions() async -> Bool {
        let username = NSUserName()
        let scriptSource = """
        do shell script "mkdir -p /etc/sudoers.d && echo '\(username) ALL=(ALL) NOPASSWD: /usr/bin/pmset' > /etc/sudoers.d/insomniac && chmod 0440 /etc/sudoers.d/insomniac" with administrator privileges
        """

        return await Task.detached(priority: .userInitiated) {
            var error: NSDictionary?
            if let script = NSAppleScript(source: scriptSource) {
                script.executeAndReturnError(&error)
                return error == nil
            }
            return false
        }.value
    }

    func removePermissions() async {
        _hasSudoPermissions = nil

        let scriptSource = """
        do shell script "rm -f /etc/sudoers.d/insomniac" with administrator privileges
        """

        await Task.detached(priority: .userInitiated) {
            var error: NSDictionary?
            if let script = NSAppleScript(source: scriptSource) {
                script.executeAndReturnError(&error)
            }
        }.value
    }

    func setSleepDisabled(_ disabled: Bool) async {
        let hasPerms = await hasPermissions()
        if !hasPerms {
            let requested = await requestPermissions()
            guard requested else {
                logger.error("Failed to acquire required permissions.")
                return
            }
            _hasSudoPermissions = true
        }

        isSleepDisabled = disabled

        if disabled {
            let current = await getDisplaySleepValues()
            if let battery = current.battery, originalDisplaySleepBattery == nil {
                originalDisplaySleepBattery = battery
                UserDefaults.standard.set(battery, forKey: batteryKey)
            }
            if let ac = current.ac, originalDisplaySleepAC == nil {
                originalDisplaySleepAC = ac
                UserDefaults.standard.set(ac, forKey: acKey)
            }
            disableScreensaver()
            await runSudoPmset(args: ["-a", "displaysleep", "0"])
        } else {
            restoreScreensaver()
            await setDisplaySleep(battery: originalDisplaySleepBattery, ac: originalDisplaySleepAC)
            originalDisplaySleepBattery = nil
            originalDisplaySleepAC = nil
            UserDefaults.standard.removeObject(forKey: batteryKey)
            UserDefaults.standard.removeObject(forKey: acKey)
        }

        let value = disabled ? "1" : "0"
        await runSudoPmset(args: ["-a", "disablesleep", value])
    }
}
