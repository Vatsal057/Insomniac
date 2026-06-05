import Foundation
import OSLog
import AppKit
import IOKit
import UserNotifications

@Observable @MainActor
final class SleepManager {
    static let shared = SleepManager()

    private let logger = Logger(subsystem: "com.insomniac.app", category: "SleepManager")

    struct DurationOption: Identifiable, Hashable {
        let id: String
        let title: String
        let seconds: TimeInterval?

        static let indefinite = DurationOption(id: "indefinite", title: "Indefinitely", seconds: nil)
        static let thirtyMinutes = DurationOption(id: "30m", title: "30 minutes", seconds: 30 * 60)
        static let oneHour = DurationOption(id: "1h", title: "1 hour", seconds: 60 * 60)
        static let threeHours = DurationOption(id: "3h", title: "3 hours", seconds: 3 * 60 * 60)
        static let eightHours = DurationOption(id: "8h", title: "8 hours", seconds: 8 * 60 * 60)

        static let presets: [DurationOption] = [
            .thirtyMinutes, .oneHour, .threeHours, .eightHours
        ]
    }

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

    private(set) var sleepDisabledUntil: Date?

    var remainingTime: TimeInterval? {
        guard let until = sleepDisabledUntil else { return nil }
        let remaining = until.timeIntervalSinceNow
        return remaining > 0 ? remaining : nil
    }

    nonisolated private let rootDomain: io_service_t
    private var _hasSudoPermissions: Bool?
    private var isToggling = false
    private var durationTask: Task<Void, any Error>?

    let autoDeactivateKey = "autoDeactivateOnSleep"
    var autoDeactivateOnSleep: Bool {
        get { UserDefaults.standard.bool(forKey: autoDeactivateKey) }
        set { UserDefaults.standard.set(newValue, forKey: autoDeactivateKey) }
    }

    let defaultDurationKey = "defaultSleepDurationSeconds"
    var defaultDuration: TimeInterval? {
        get {
            let val = UserDefaults.standard.double(forKey: defaultDurationKey)
            return val > 0 ? val : nil
        }
        set {
            if let newValue, newValue > 0 {
                UserDefaults.standard.set(newValue, forKey: defaultDurationKey)
            } else {
                UserDefaults.standard.removeObject(forKey: defaultDurationKey)
            }
        }
    }

    let useCaffeinateKey = "useCaffeinateMode"
    var useCaffeinate: Bool {
        get { UserDefaults.standard.bool(forKey: useCaffeinateKey) }
        set { UserDefaults.standard.set(newValue, forKey: useCaffeinateKey) }
    }

    let requireChargingKey = "requireCharging"
    var requireCharging: Bool {
        get { UserDefaults.standard.bool(forKey: requireChargingKey) }
        set { UserDefaults.standard.set(newValue, forKey: requireChargingKey) }
    }

    let watchedAppsKey = "watchedAppBundleIDs"
    var watchedAppBundleIDs: [String] {
        get { UserDefaults.standard.stringArray(forKey: watchedAppsKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: watchedAppsKey) }
    }

    // Schedule
    let scheduleEnabledKey = "scheduleEnabled"
    var scheduleEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: scheduleEnabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: scheduleEnabledKey) }
    }
    var scheduleStartHour: Int {
        get { UserDefaults.standard.object(forKey: "scheduleStartHour") as? Int ?? 9 }
        set { UserDefaults.standard.set(newValue, forKey: "scheduleStartHour") }
    }
    var scheduleStartMinute: Int {
        get { UserDefaults.standard.object(forKey: "scheduleStartMinute") as? Int ?? 0 }
        set { UserDefaults.standard.set(newValue, forKey: "scheduleStartMinute") }
    }
    var scheduleEndHour: Int {
        get { UserDefaults.standard.object(forKey: "scheduleEndHour") as? Int ?? 17 }
        set { UserDefaults.standard.set(newValue, forKey: "scheduleEndHour") }
    }
    var scheduleEndMinute: Int {
        get { UserDefaults.standard.object(forKey: "scheduleEndMinute") as? Int ?? 0 }
        set { UserDefaults.standard.set(newValue, forKey: "scheduleEndMinute") }
    }
    var scheduleDays: Set<Int> {
        get {
            let stored = UserDefaults.standard.array(forKey: "scheduleDays") as? [Int] ?? []
            return Set(stored)
        }
        set { UserDefaults.standard.set(Array(newValue), forKey: "scheduleDays") }
    }

    // Activity-based
    let activityBasedEnabledKey = "activityBasedEnabled"
    var activityBasedEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: activityBasedEnabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: activityBasedEnabledKey) }
    }
    var activityThresholdPercent: Int {
        get { (UserDefaults.standard.object(forKey: "activityThresholdPercent") as? Int) ?? 25 }
        set { UserDefaults.standard.set(newValue, forKey: "activityThresholdPercent") }
    }
    var activityIdleTimeoutSeconds: Int {
        get { (UserDefaults.standard.object(forKey: "activityIdleTimeoutSeconds") as? Int) ?? 60 }
        set { UserDefaults.standard.set(newValue, forKey: "activityIdleTimeoutSeconds") }
    }

    // Network (SSID)
    let networkBasedEnabledKey = "networkBasedEnabled"
    var networkBasedEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: networkBasedEnabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: networkBasedEnabledKey) }
    }
    var watchedNetworks: [String] {
        get { (UserDefaults.standard.array(forKey: "watchedNetworks") as? [String]) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: "watchedNetworks") }
    }

    // Power-event exclusions
    var dimOnBatteryOnly: Bool {
        get { UserDefaults.standard.bool(forKey: "dimOnBatteryOnly") }
        set { UserDefaults.standard.set(newValue, forKey: "dimOnBatteryOnly") }
    }
    var skipDimOnExternalDisplay: Bool {
        get { UserDefaults.standard.bool(forKey: "skipDimOnExternalDisplay") }
        set { UserDefaults.standard.set(newValue, forKey: "skipDimOnExternalDisplay") }
    }

    private var caffeinateProcess: Process?

    private let firstLaunchKey = "hasLaunchedBefore"
    var isFirstLaunch: Bool { !UserDefaults.standard.bool(forKey: firstLaunchKey) }

    private var notifyPort: IONotificationPortRef?
    private var lidNotification: io_object_t = 0
    private var dimTask: Task<Void, any Error>?

    private let batteryKey = "originalDisplaySleepBattery"
    private let acKey = "originalDisplaySleepAC"
    private var originalDisplaySleepBattery: Int?
    private var originalDisplaySleepAC: Int?

    private init() {
        self.rootDomain = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))

        originalDisplaySleepBattery = UserDefaults.standard.object(forKey: batteryKey) as? Int
        originalDisplaySleepAC = UserDefaults.standard.object(forKey: acKey) as? Int

        setupTerminationObserver()
        setupSleepNotificationObserver()
        setupPowerMonitor()
        setupAppMonitor()
        startSchedule()
        startActivityMonitor()
        startNetworkMonitor()

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

    func updateWatchedApps() {
        AppMonitor.shared.updateWatchedBundleIDs(Set(watchedAppBundleIDs))
    }

    // MARK: - Schedule

    private var scheduleTimer: Timer?
    private var wasInScheduledWindow = false

    func startSchedule() {
        scheduleTimer?.invalidate()
        wasInScheduledWindow = isInScheduledWindow()
        scheduleTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkSchedule()
            }
        }
        checkSchedule()
    }

    private func checkSchedule() {
        guard scheduleEnabled else { return }
        let inWindow = isInScheduledWindow()
        if inWindow && !wasInScheduledWindow && !isSleepDisabled && !isToggling {
            sleepDisabledUntil = nil
            durationTask = nil
            Task {
                await setSleepDisabled(true)
                sendNotification(
                    title: "Sleep Prevention Enabled",
                    body: "Scheduled window started."
                )
            }
        } else if !inWindow && wasInScheduledWindow && isSleepDisabled {
            sleepDisabledUntil = nil
            durationTask = nil
            Task {
                await setSleepDisabled(false)
                sendNotification(
                    title: "Sleep Prevention Disabled",
                    body: "Scheduled window ended."
                )
            }
        }
        wasInScheduledWindow = inWindow
    }

    private func isInScheduledWindow() -> Bool {
        let now = Date()
        let calendar = Calendar.current
        let weekday = calendar.component(.weekday, from: now)
        guard scheduleDays.contains(weekday) else { return false }

        let hour = calendar.component(.hour, from: now)
        let minute = calendar.component(.minute, from: now)
        let nowMinutes = hour * 60 + minute
        let startMinutes = scheduleStartHour * 60 + scheduleStartMinute
        let endMinutes = scheduleEndHour * 60 + scheduleEndMinute

        if startMinutes <= endMinutes {
            return nowMinutes >= startMinutes && nowMinutes < endMinutes
        } else {
            // Window crosses midnight
            return nowMinutes >= startMinutes || nowMinutes < endMinutes
        }
    }

    // MARK: - Activity monitor

    private var activityTimer: Timer?

    func startActivityMonitor() {
        activityTimer?.invalidate()
        guard activityBasedEnabled else { return }

        activityTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkActivity()
            }
        }
        checkActivity()
    }

    private func checkActivity() {
        guard activityBasedEnabled, !isToggling else { return }

        let cpu = ActivityMonitor.shared.cpuUsagePercent
        let idle = ActivityMonitor.shared.systemIdleTime
        let threshold = Double(activityThresholdPercent)
        let idleTimeout = TimeInterval(activityIdleTimeoutSeconds)

        let isActive = cpu >= threshold || idle < idleTimeout

        if isActive && !isSleepDisabled {
            if requireCharging && !PowerMonitor.shared.isOnACPower { return }
            sleepDisabledUntil = nil
            durationTask = nil
            Task {
                await setSleepDisabled(true)
                sendNotification(
                    title: "Sleep Prevention Enabled",
                    body: "Activity detected (CPU \(Int(cpu))%)."
                )
            }
        } else if !isActive && isSleepDisabled {
            sleepDisabledUntil = nil
            durationTask = nil
            Task {
                await setSleepDisabled(false)
                sendNotification(
                    title: "Sleep Prevention Disabled",
                    body: "System has been idle."
                )
            }
        }
    }

    // MARK: - Network monitor

    func startNetworkMonitor() {
        NetworkMonitor.shared.start { [weak self] ssid in
            Task { @MainActor in
                self?.checkNetwork(ssid: ssid)
            }
        }
        checkNetwork(ssid: NetworkMonitor.shared.currentSSID)
    }

    private func checkNetwork(ssid: String?) {
        guard networkBasedEnabled, !isToggling else { return }

        let isOnWatchedNetwork = ssid.map { watchedNetworks.contains($0) } ?? false

        if isOnWatchedNetwork && !isSleepDisabled {
            if requireCharging && !PowerMonitor.shared.isOnACPower { return }
            sleepDisabledUntil = nil
            durationTask = nil
            Task {
                await setSleepDisabled(true)
                sendNotification(
                    title: "Sleep Prevention Enabled",
                    body: "Connected to \(ssid ?? "watched network")."
                )
            }
        } else if !isOnWatchedNetwork && isSleepDisabled {
            sleepDisabledUntil = nil
            durationTask = nil
            Task {
                await setSleepDisabled(false)
                sendNotification(
                    title: "Sleep Prevention Disabled",
                    body: ssid.map { "Switched to \($0)." } ?? "Disconnected from Wi-Fi."
                )
            }
        }
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
                self.caffeinateProcess?.terminate()
                self.caffeinateProcess = nil
                if self.isSleepDisabled {
                    await self.setSleepDisabled(false)
                }
            }
        }
    }

    private func setupPowerMonitor() {
        PowerMonitor.shared.start { [weak self] isOnAC in
            Task { @MainActor in
                guard let self, self.requireCharging, self.isSleepDisabled else { return }
                if !isOnAC {
                    // Unplugged — auto-deactivate
                    self.durationTask?.cancel()
                    self.durationTask = nil
                    self.sleepDisabledUntil = nil
                    await self.setSleepDisabled(false)
                    self.sendNotification(
                        title: "Sleep Prevention Disabled",
                        body: "Unplugged. Battery preservation enabled."
                    )
                }
            }
        }
    }

    private func setupAppMonitor() {
        AppMonitor.shared.start(
            bundleIDs: Set(watchedAppBundleIDs),
            onAnyWatchedRunning: { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    guard !self.isSleepDisabled, !self.isToggling else { return }
                    if self.requireCharging && !PowerMonitor.shared.isOnACPower { return }
                    self.sleepDisabledUntil = nil
                    self.durationTask = nil
                    await self.setSleepDisabled(true)
                    self.sendNotification(
                        title: "Sleep Prevention Enabled",
                        body: "A watched app is running."
                    )
                }
            },
            onAllWatchedGone: { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    guard self.isSleepDisabled, self.watchedAppBundleIDs.count > 0 else { return }
                    self.sleepDisabledUntil = nil
                    self.durationTask = nil
                    await self.setSleepDisabled(false)
                    self.sendNotification(
                        title: "Sleep Prevention Disabled",
                        body: "All watched apps have closed."
                    )
                }
            }
        )
    }

    private func setupSleepNotificationObserver() {
        NotificationCenter.default.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.autoDeactivateOnSleep, self.isSleepDisabled else { return }
                self.durationTask?.cancel()
                self.durationTask = nil
                self.sleepDisabledUntil = nil
                await self.setSleepDisabled(false)
            }
        }
    }

    // MARK: - Notifications

    func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: .alert) { _, _ in }
    }

    private func sendNotification(title: String, body: String) {
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
            // Skip dimming if external display is attached and user opted in
            if skipDimOnExternalDisplay && isExternalDisplayConnected() {
                return
            }
            // Skip dimming on battery if user opted out of dimming while unplugged
            if dimOnBatteryOnly && PowerMonitor.shared.isOnACPower {
                return
            }
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

    /// Returns true if any display other than the built-in one is connected.
    private func isExternalDisplayConnected() -> Bool {
        let maxDisplays: UInt32 = 8
        var displayIds = [CGDirectDisplayID](repeating: 0, count: Int(maxDisplays))
        var actualCount: UInt32 = 0

        let result = CGGetActiveDisplayList(maxDisplays, &displayIds, &actualCount)
        guard result == .success else { return false }

        let mainDisplay = CGMainDisplayID()
        for i in 0..<Int(actualCount) where displayIds[i] != mainDisplay {
            return true
        }
        return false
    }

    // MARK: - Toggle

    func toggleSleep() {
        if isSleepDisabled {
            disableSleep()
        } else {
            enableSleep(duration: defaultDuration)
        }
    }

    func enableSleep(duration: TimeInterval?) {
        guard !isToggling else { return }

        if requireCharging && !PowerMonitor.shared.isOnACPower {
            sendNotification(
                title: "Cannot Enable Sleep Prevention",
                body: "Your Mac must be plugged in (set in Settings)."
            )
            return
        }

        isToggling = true

        durationTask?.cancel()
        durationTask = nil

        if let duration, duration > 0 {
            sleepDisabledUntil = Date().addingTimeInterval(duration)
        } else {
            sleepDisabledUntil = nil
        }

        Task {
            await setSleepDisabled(true)
            isToggling = false

            if let duration, duration > 0 {
                scheduleDurationExpiration(duration: duration)
                let formatted = formatDuration(duration)
                sendNotification(
                    title: "Sleep Prevention Enabled",
                    body: "Your Mac will stay awake for \(formatted)."
                )
            } else {
                sendNotification(
                    title: "Sleep Prevention Enabled",
                    body: "Your Mac will stay awake indefinitely."
                )
            }
        }
    }

    func disableSleep() {
        guard !isToggling else { return }
        isToggling = true

        durationTask?.cancel()
        durationTask = nil
        sleepDisabledUntil = nil

        Task {
            await setSleepDisabled(false)
            isToggling = false
            sendNotification(
                title: "Sleep Prevention Disabled",
                body: "Your Mac can now sleep normally."
            )
        }
    }

    private func scheduleDurationExpiration(duration: TimeInterval) {
        durationTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
                guard let self, self.isSleepDisabled else { return }
                self.sleepDisabledUntil = nil
                await self.setSleepDisabled(false)
                self.sendNotification(
                    title: "Sleep Prevention Expired",
                    body: "Your Mac can now sleep normally."
                )
            } catch is CancellationError {}
        }
    }

    // MARK: - Formatting

    func formatRemainingTime() -> String? {
        guard let remaining = remainingTime else { return nil }
        return formatDuration(remaining)
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 && minutes > 0 {
            return "\(hours)h \(minutes)m"
        } else if hours > 0 {
            return "\(hours) hour\(hours == 1 ? "" : "s")"
        } else if minutes > 0 {
            return "\(minutes) minute\(minutes == 1 ? "" : "s")"
        } else {
            return "less than a minute"
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

    func setSleepDisabled(_ disabled: Bool) async {
        if useCaffeinate {
            await setSleepDisabledCaffeinate(disabled)
            isSleepDisabled = disabled
            return
        }

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
            await runSudoPmset(args: ["-a", "displaysleep", "0"])
        } else {
            await setDisplaySleep(battery: originalDisplaySleepBattery, ac: originalDisplaySleepAC)
            originalDisplaySleepBattery = nil
            originalDisplaySleepAC = nil
            UserDefaults.standard.removeObject(forKey: batteryKey)
            UserDefaults.standard.removeObject(forKey: acKey)
        }

        let value = disabled ? "1" : "0"
        await runSudoPmset(args: ["-a", "disablesleep", value])
    }

    private func setSleepDisabledCaffeinate(_ enabled: Bool) async {
        caffeinateProcess?.terminate()
        caffeinateProcess = nil

        guard enabled else { return }

        let process = await Task.detached(priority: .userInitiated) { () -> Process? in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
            process.arguments = ["-di"]
            do {
                try process.run()
                return process
            } catch {
                return nil
            }
        }.value

        guard let process else {
            logger.error("Failed to launch caffeinate")
            return
        }

        caffeinateProcess = process

        // If caffeinate dies for any reason (e.g. user kills it in Activity
        // Monitor), treat sleep as no longer disabled.
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.caffeinateProcess === process {
                    self.caffeinateProcess = nil
                    if self.isSleepDisabled {
                        self.isSleepDisabled = false
                        self.sendNotification(
                            title: "Sleep Prevention Disabled",
                            body: "The caffeinate process ended unexpectedly."
                        )
                    }
                }
            }
        }
    }
}
