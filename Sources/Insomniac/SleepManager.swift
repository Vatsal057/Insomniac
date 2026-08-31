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
        
        static let custom = DurationOption(id: "custom", title: "Custom...", seconds: -1)

        static func custom(seconds: TimeInterval) -> DurationOption {
            let minutes = Int(seconds / 60)
            let hours = minutes / 60
            let title: String
            if hours > 0 && minutes % 60 == 0 {
                title = "\(hours) hour\(hours > 1 ? "s" : "")"
            } else if hours > 0 {
                title = "\(hours)h \(minutes % 60)m"
            } else {
                title = "\(minutes) minute\(minutes > 1 ? "s" : "")"
            }
            return DurationOption(id: "custom_\(seconds)", title: title, seconds: seconds)
        }
    }

    private(set) var isSleepDisabled: Bool = false {
        didSet {
            if isSleepDisabled {
                startLidMonitor()
                NSSound(named: "Glass")?.play()
            } else {
                stopLidMonitor()
                DisplayManager.shared.restoreScreen()
                NSSound(named: "Tink")?.play()
            }
            // Deferred so this is safe when fired from within our own init
            // (MouseManager reads SleepManager.shared).
            Task { @MainActor in
                MouseManager.shared.updateTimerState()
            }
        }
    }

    private(set) var sleepDisabledUntil: Date?

    /// What started the current session.
    ///
    /// Every automatic trigger used to end *any* active session, not just its
    /// own. Two triggers that disagree — a scheduled window that wants the Mac
    /// awake while the activity monitor sees an idle machine — would then flip
    /// the session on and off against each other every tick, with a
    /// notification and a system sound each time. Worse, an automatic trigger
    /// could quietly cancel a session the user had started by hand.
    ///
    /// So an automatic trigger may only switch off what it switched on.
    /// Safety cutoffs (thermal, low battery, unplugged, system sleep) and
    /// anything the user does are exempt and always win.
    enum SessionOwner: Equatable {
        case manual
        case schedule
        case watchedApp
        case download
    }

    private(set) var sessionOwner: SessionOwner?

    /// True when `owner` is allowed to end the current session.
    private func canRelinquish(_ owner: SessionOwner) -> Bool {
        sessionOwner == owner
    }

    var remainingTime: TimeInterval? {
        guard let until = sleepDisabledUntil else { return nil }
        let remaining = until.timeIntervalSinceNow
        return remaining > 0 ? remaining : nil
    }

    nonisolated private let rootDomain: io_service_t
    private var _hasSudoPermissions: Bool?
    private var isToggling = false
    private var durationTask: Task<Void, any Error>?

    /// Cancels any pending duration-expiration task and clears the countdown.
    private func clearSession() {
        durationTask?.cancel()
        durationTask = nil
        sleepDisabledUntil = nil
    }

    /// Runs one automatic on/off transition, serialized against every other
    /// trigger.
    ///
    /// The `!isToggling` checks scattered through the trigger callbacks read the
    /// flag but never set it, so two triggers firing in the same tick both got
    /// through and raced their `setSleepDisabled` calls. Routing them all
    /// through here makes the flag mean what it says.
    private func performAutomatic(
        enable: Bool,
        owner: SessionOwner,
        title: String,
        body: String
    ) async {
        guard !isToggling else { return }
        if enable {
            guard !isSleepDisabled else { return }
        } else {
            guard isSleepDisabled, canRelinquish(owner) else { return }
        }

        isToggling = true
        clearSession()
        await setSleepDisabled(enable)
        isToggling = false

        // `setSleepDisabled` refuses to claim a session pmset wouldn't grant,
        // so only report what actually happened.
        guard isSleepDisabled == enable else { return }
        sessionOwner = enable ? owner : nil
        sendNotification(title: title, body: body)
    }

    /// Ends the session regardless of who started it. For safety cutoffs and
    /// user-initiated changes.
    private func forceDisable(title: String, body: String) async {
        guard isSleepDisabled else { return }
        isToggling = true
        clearSession()
        await setSleepDisabled(false)
        isToggling = false
        sessionOwner = nil
        sendNotification(title: title, body: body)
    }

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

    // Thermal guard
    var thermalGuardEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "thermalGuardEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "thermalGuardEnabled") }
    }
    var thermalGuardCriticalOnly: Bool {
        get { UserDefaults.standard.bool(forKey: "thermalGuardCriticalOnly") }
        set { UserDefaults.standard.set(newValue, forKey: "thermalGuardCriticalOnly") }
    }

    // Low-battery cutoff
    var batteryCutoffEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "batteryCutoffEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "batteryCutoffEnabled") }
    }
    var batteryCutoffPercent: Int {
        get { (UserDefaults.standard.object(forKey: "batteryCutoffPercent") as? Int) ?? 20 }
        set { UserDefaults.standard.set(newValue, forKey: "batteryCutoffPercent") }
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

    // The CPU/activity trigger was removed. There is no "CPU went above 25%"
    // notification to subscribe to, so it had to sample every 30s — an app
    // spending CPU to measure CPU, forever, to decide something the user can
    // express far more cheaply with the app-watch or download triggers.

    // The Wi-Fi (SSID) trigger was removed. macOS offers no cheap event for
    // "the network changed name", so it had to poll — and each poll forked
    // /usr/sbin/networksetup twice. That was by far the most expensive thing
    // in the app, running every 30s for as long as it was switched on.

    // Power-event exclusions
    var dimOnBatteryOnly: Bool {
        get { UserDefaults.standard.bool(forKey: "dimOnBatteryOnly") }
        set { UserDefaults.standard.set(newValue, forKey: "dimOnBatteryOnly") }
    }
    var skipDimOnExternalDisplay: Bool {
        get { UserDefaults.standard.bool(forKey: "skipDimOnExternalDisplay") }
        set { UserDefaults.standard.set(newValue, forKey: "skipDimOnExternalDisplay") }
    }

    // Launch Behavior
    let startSessionOnLaunchKey = "startSessionOnLaunch"
    var startSessionOnLaunch: Bool {
        get { UserDefaults.standard.bool(forKey: startSessionOnLaunchKey) }
        set { UserDefaults.standard.set(newValue, forKey: startSessionOnLaunchKey) }
    }

    /// Show a live countdown next to the menu bar icon.
    ///
    /// Off by default, because it's the only thing left in the app that needs a
    /// repeating timer. With it off, an active session costs nothing and the
    /// remaining time is still visible in the menu.
    let showMenuBarCountdownKey = "showMenuBarCountdown"
    var showMenuBarCountdown: Bool {
        get { UserDefaults.standard.bool(forKey: showMenuBarCountdownKey) }
        set { UserDefaults.standard.set(newValue, forKey: showMenuBarCountdownKey) }
    }

    // Quick-Start Toggle Action
    let quickStartToggleStyleKey = "quickStartToggleStyle"
    var quickStartToggleStyle: String {
        get { UserDefaults.standard.string(forKey: quickStartToggleStyleKey) ?? "leftClickToggle" }
        set { UserDefaults.standard.set(newValue, forKey: quickStartToggleStyleKey) }
    }

    // File Download Watcher
    let downloadWatcherEnabledKey = "downloadWatcherEnabled"
    var downloadWatcherEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: downloadWatcherEnabledKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: downloadWatcherEnabledKey)
            if newValue {
                startDownloadWatcher()
            } else {
                stopDownloadWatcher()
            }
        }
    }

    let downloadWatcherPathKey = "downloadWatcherPath"
    var downloadWatcherPath: String {
        get {
            UserDefaults.standard.string(forKey: downloadWatcherPathKey) ??
                (FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.path ?? "")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: downloadWatcherPathKey)
        }
    }

    /// Watches the folder for changes instead of re-reading it on a timer.
    ///
    /// This used to poll every 5 seconds forever, which was the app's most
    /// frequent wake-up by a wide margin. The kernel already knows when a
    /// directory changes and will say so, so there's no reason to keep asking.
    private var downloadWatcher: FolderWatcher?
    private var isDownloadingHeld = false

    func startDownloadWatcher() {
        downloadWatcher = nil
        guard downloadWatcherEnabled else { return }

        let path = downloadWatcherPath
        guard !path.isEmpty else { return }

        downloadWatcher = FolderWatcher(path: path) { [weak self] in
            self?.checkDownloads()
        }
        // One read now to catch a download already in flight.
        checkDownloads()
    }

    func stopDownloadWatcher() {
        downloadWatcher = nil
        if isDownloadingHeld {
            isDownloadingHeld = false
            Task {
                await performAutomatic(
                    enable: false,
                    owner: .download,
                    title: "Sleep Prevention Disabled",
                    body: "Downloads completed."
                )
            }
        }
    }

    private func checkDownloads() {
        guard downloadWatcherEnabled, !isToggling else { return }

        let path = downloadWatcherPath
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else { return }

        do {
            let files = try FileManager.default.contentsOfDirectory(atPath: path)
            let activeDownload = files.contains { file in
                let lower = file.lowercased()
                return lower.hasSuffix(".crdownload") ||
                       lower.hasSuffix(".download") ||
                       lower.hasSuffix(".part") ||
                       lower.hasSuffix(".tmp")
            }

            if activeDownload && !isSleepDisabled && !isDownloadingHeld {
                isDownloadingHeld = true
                Task {
                    await performAutomatic(
                        enable: true,
                        owner: .download,
                        title: "Sleep Prevention Enabled",
                        body: "Active download detected in watched folder."
                    )
                }
            } else if !activeDownload && isDownloadingHeld {
                isDownloadingHeld = false
                Task {
                    await performAutomatic(
                        enable: false,
                        owner: .download,
                        title: "Sleep Prevention Disabled",
                        body: "Downloads completed."
                    )
                }
            }
        } catch {
            logger.error("Failed to read downloads directory: \(error.localizedDescription)")
        }
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
        setupClockChangeObserver()
        setupPowerMonitor()
        setupAppMonitor()
        startSchedule()
        startDownloadWatcher()
        startThermalMonitor()

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

    /// Arms a single timer for the next window boundary.
    ///
    /// This used to tick every 60 seconds just to compare the clock — 1,440
    /// wake-ups a day to notice at most two transitions. Now it works out when
    /// the next edge actually is and sleeps until then.
    func startSchedule() {
        scheduleTimer?.invalidate()
        scheduleTimer = nil
        // Seed false so enabling the schedule mid-window activates immediately.
        wasInScheduledWindow = false
        guard scheduleEnabled else { return }
        checkSchedule()
        armScheduleTimer()
    }

    private func armScheduleTimer() {
        scheduleTimer?.invalidate()
        scheduleTimer = nil
        guard scheduleEnabled else { return }

        guard let next = nextScheduleBoundary(after: Date()) else {
            // No days selected, so no boundary will ever arrive. Nothing to arm;
            // toggling a day re-runs startSchedule().
            return
        }

        // A minute past the edge, so rounding can't land us just before it and
        // read the old state.
        let fireAt = max(next.timeIntervalSinceNow + 1, 1)
        let timer = Timer.scheduledTimer(withTimeInterval: fireAt, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.checkSchedule()
                self.armScheduleTimer()
            }
        }
        // Generous slack: macOS can fold this into a wake it was making anyway.
        timer.tolerance = 30
        scheduleTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    /// The next moment the in-window answer changes, searching forward up to a
    /// week. Returns nil when no day is selected.
    ///
    /// Built from `Calendar` date components rather than by adding seconds, so
    /// daylight-saving transitions land on the right wall-clock time.
    func nextScheduleBoundary(after now: Date) -> Date? {
        guard !scheduleDays.isEmpty else { return nil }
        let calendar = Calendar.current
        let start = (hour: scheduleStartHour, minute: scheduleStartMinute)
        let end = (hour: scheduleEndHour, minute: scheduleEndMinute)

        var candidates: [Date] = []
        // Today plus the next 7 days covers every weekday, and covers a window
        // whose end falls on the day after its start.
        for dayOffset in 0...7 {
            guard let day = calendar.date(byAdding: .day, value: dayOffset, to: now) else { continue }
            for edge in [start, end] {
                guard let edgeDate = calendar.date(
                    bySettingHour: edge.hour, minute: edge.minute, second: 0, of: day
                ) else { continue }
                if edgeDate > now { candidates.append(edgeDate) }
            }
        }
        return candidates.min()
    }

    private func checkSchedule() {
        guard scheduleEnabled else { return }
        let inWindow = isInScheduledWindow()
        if inWindow && !wasInScheduledWindow {
            Task {
                await performAutomatic(
                    enable: true,
                    owner: .schedule,
                    title: "Sleep Prevention Enabled",
                    body: "Scheduled window started."
                )
            }
        } else if !inWindow && wasInScheduledWindow {
            Task {
                await performAutomatic(
                    enable: false,
                    owner: .schedule,
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

    // MARK: - Thermal guard

    func startThermalMonitor() {
        ThermalMonitor.shared.stop()
        guard thermalGuardEnabled else { return }
        ThermalMonitor.shared.start { [weak self] state in
            Task { @MainActor in self?.checkThermal(state) }
        }
        checkThermal(ThermalMonitor.shared.currentState)
    }

    private func checkThermal(_ state: ProcessInfo.ThermalState) {
        guard thermalGuardEnabled, isSleepDisabled, !isToggling else { return }
        guard ThermalMonitor.isHot(state, criticalOnly: thermalGuardCriticalOnly) else { return }
        // A safety cutoff overrides whoever owns the session, including the user.
        Task {
            await forceDisable(
                title: "Sleep Prevention Disabled",
                body: "Your Mac is running hot. Sleep prevention paused for safety."
            )
        }
    }

    // MARK: - Low-battery cutoff

    /// Disables sleep prevention when on battery at or below the cutoff.
    /// Called from the power-change callback and the app's 30s tick (battery %
    /// drifts without firing a power event).
    func checkBatteryCutoff() {
        guard batteryCutoffEnabled, isSleepDisabled, !isToggling else { return }
        guard !PowerMonitor.shared.isOnACPower else { return }
        guard let pct = PowerMonitor.shared.batteryPercent, pct <= batteryCutoffPercent else { return }
        // Safety cutoff — overrides the session owner.
        Task {
            await forceDisable(
                title: "Sleep Prevention Disabled",
                body: "Battery at \(pct)% (cutoff \(batteryCutoffPercent)%)."
            )
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
                self?.caffeinateProcess?.terminate()
                self?.caffeinateProcess = nil
            }
        }
    }

    private func setupPowerMonitor() {
        PowerMonitor.shared.start { [weak self] isOnAC in
            Task { @MainActor in
                guard let self else { return }
                self.checkBatteryCutoff()
                guard self.requireCharging, self.isSleepDisabled else { return }
                if !isOnAC {
                    // Unplugged — the user asked for AC-only, so this overrides
                    // whoever owns the session.
                    await self.forceDisable(
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
                    if self.requireCharging && !PowerMonitor.shared.isOnACPower { return }
                    await self.performAutomatic(
                        enable: true,
                        owner: .watchedApp,
                        title: "Sleep Prevention Enabled",
                        body: "A watched app is running."
                    )
                }
            },
            onAllWatchedGone: { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    guard !self.watchedAppBundleIDs.isEmpty else { return }
                    await self.performAutomatic(
                        enable: false,
                        owner: .watchedApp,
                        title: "Sleep Prevention Disabled",
                        body: "All watched apps have closed."
                    )
                }
            }
        )
    }

    /// Re-arms the schedule timer whenever the clock it was measured against
    /// moves.
    ///
    /// The timer now waits hours rather than a minute, and `Timer` counts
    /// elapsed time, not wall-clock time. So a system sleep, a timezone change,
    /// or an NTP correction would all leave it aimed at the wrong moment. These
    /// are all notifications, so noticing costs nothing.
    private func setupClockChangeObserver() {
        let rearm: @Sendable (Notification) -> Void = { [weak self] _ in
            Task { @MainActor in
                guard let self, self.scheduleEnabled else { return }
                self.checkSchedule()
                self.armScheduleTimer()
            }
        }

        for name in [NSNotification.Name.NSSystemClockDidChange,
                     NSNotification.Name.NSSystemTimeZoneDidChange] {
            NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main, using: rearm
            )
        }

        // Waking from sleep is the common case: the deadline slipped by however
        // long the Mac was asleep.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main, using: rearm
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
                self.clearSession()
                await self.setSleepDisabled(false)
                self.sessionOwner = nil
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

        clearSession()

        if let duration, duration > 0 {
            sleepDisabledUntil = Date().addingTimeInterval(duration)
        }

        Task {
            await setSleepDisabled(true)
            isToggling = false

            guard isSleepDisabled else {
                // Permission was denied — don't claim success.
                sleepDisabledUntil = nil
                sessionOwner = nil
                sendNotification(
                    title: "Could Not Enable Sleep Prevention",
                    body: "Insomniac needs permission to run pmset."
                )
                return
            }

            // Claimed by the user, so no automatic trigger may end it.
            sessionOwner = .manual

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

        clearSession()

        Task {
            await setSleepDisabled(false)
            isToggling = false
            guard !isSleepDisabled else { return }
            sessionOwner = nil
            sendNotification(
                title: "Sleep Prevention Disabled",
                body: "Your Mac can now sleep normally."
            )
        }
    }

    /// Waits out a timed session, then restores sleep.
    ///
    /// Sleeps until the deadline in one go rather than waking every second to
    /// compare two dates — an 8-hour session was ~28,800 pointless wake-ups, and
    /// the menu bar only ever displays whole minutes anyway. The loop remains
    /// because `Task.sleep` measures elapsed time, not wall-clock time, so a
    /// system sleep mid-countdown can return early; when that happens it just
    /// waits again for whatever is left.
    private func scheduleDurationExpiration(duration: TimeInterval) {
        durationTask = Task { [weak self] in
            do {
                while true {
                    guard let self, self.isSleepDisabled, let until = self.sleepDisabledUntil else { return }
                    let remaining = until.timeIntervalSinceNow
                    if remaining <= 0 { break }
                    // Cap each wait so a very long session still re-checks the
                    // wall clock periodically.
                    let slice = min(remaining, 15 * 60)
                    try await Task.sleep(nanoseconds: UInt64(slice * 1_000_000_000))
                }
                guard let self, self.isSleepDisabled else { return }
                self.sleepDisabledUntil = nil
                await self.setSleepDisabled(false)
                self.sessionOwner = nil
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

        // pmset -g pads columns with variable whitespace.
        self.isSleepDisabled = output.range(
            of: #"(sleepdisabled|disablesleep)\s+1"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
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
            // -n: fail instead of hanging on a password prompt if the
            // sudoers entry was removed after we cached permissions.
            process.arguments = ["-n", "/usr/bin/pmset"] + args
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

    /// A login name we're willing to splice into a root shell command.
    ///
    /// Everything below runs through `do shell script … with administrator
    /// privileges`, so an unescaped quote or `$(…)` in the name would be
    /// arbitrary code execution as root. Rather than try to escape for two
    /// nested languages (AppleScript string, then sh), refuse anything that
    /// isn't a plain POSIX login name.
    static func isSafeLoginName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 32 else { return false }
        guard let first = name.first, first.isLetter || first == "_" else { return false }
        return name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
    }

    /// Grants a passwordless `sudo pmset` rule, once, behind an admin prompt.
    ///
    /// The rule is staged under a filename sudo deliberately ignores (names
    /// containing a `.` are skipped inside `sudoers.d`), validated with
    /// `visudo -c`, and only then moved into place. Writing an unvalidated file
    /// straight to `/etc/sudoers.d` risks a parse error that breaks `sudo` for
    /// the whole machine — a much worse outcome than failing to update.
    private func requestPermissions() async -> Bool {
        let username = NSUserName()
        guard Self.isSafeLoginName(username) else {
            logger.error("Refusing to write a sudoers rule for an unexpected login name.")
            return false
        }

        let final = "/etc/sudoers.d/insomniac"
        // Contains a dot, so sudo skips it while it exists — a half-written
        // staging file can never affect sudo's behaviour.
        let staged = "\(final).staging"
        let rule = "\(username) ALL=(ALL) NOPASSWD: /usr/bin/pmset"

        // No backslashes anywhere below: this string is parsed first by
        // AppleScript (where a backslash escapes) and only then by sh.
        let command = [
            "/bin/mkdir -p /etc/sudoers.d",
            "/bin/echo '\(rule)' > '\(staged)'",
            "/bin/chmod 0440 '\(staged)'",
            "/usr/sbin/chown root:wheel '\(staged)'",
            // Validate before it can ever be parsed as policy.
            "/usr/sbin/visudo -cf '\(staged)'",
            "/bin/mv '\(staged)' '\(final)'",
        ].joined(separator: " && ") + " || { /bin/rm -f '\(staged)'; exit 1; }"

        let scriptSource = """
        do shell script "\(command)" with administrator privileges
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

    /// Removes the passwordless `sudo pmset` rule this app installed.
    ///
    /// The grant outlives the app bundle, so there has to be a way back out of
    /// it that doesn't involve hand-editing `/etc/sudoers.d` in a terminal.
    @discardableResult
    func revokePermissions() async -> Bool {
        let script = """
        do shell script "/bin/rm -f /etc/sudoers.d/insomniac /etc/sudoers.d/insomniac.staging" with administrator privileges
        """
        let removed = await Task.detached(priority: .userInitiated) {
            var error: NSDictionary?
            if let applescript = NSAppleScript(source: script) {
                applescript.executeAndReturnError(&error)
                return error == nil
            }
            return false
        }.value

        if removed { _hasSudoPermissions = nil }
        return removed
    }

    /// True when a passwordless `sudo pmset` rule is currently installed.
    func hasInstalledSudoersRule() -> Bool {
        FileManager.default.fileExists(atPath: "/etc/sudoers.d/insomniac")
    }

    func setSleepDisabled(_ disabled: Bool) async {
        if useCaffeinate {
            let ok = await setSleepDisabledCaffeinate(disabled)
            // Turning prevention *off* always succeeds — the process is gone
            // either way. Only a failed launch means we aren't holding it.
            guard ok || !disabled else {
                isSleepDisabled = false
                Watchdog.shared.stop()
                return
            }
            isSleepDisabled = disabled
            Watchdog.shared.stop() // caffeinate mode never needs the watchdog
            return
        }

        let hasPerms = await hasPermissions()
        if !hasPerms {
            // Only ever prompt to *start* a session. Turning prevention off
            // without the grant is a no-op anyway (nothing set the flag), and
            // asking here would pop an admin dialog during app termination.
            guard disabled else {
                isSleepDisabled = false
                sleepDisabledUntil = nil
                sessionOwner = nil
                Watchdog.shared.stop()
                return
            }
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
        let applied = await runSudoPmset(args: ["-a", "disablesleep", value])

        // `pmset` is the thing that actually holds the machine awake. If it
        // refused (sudoers rule removed behind our back, pmset unavailable),
        // reporting success would leave the menu bar claiming a session that
        // doesn't exist — and the Mac would sleep mid-download.
        if disabled && !applied {
            logger.error("pmset refused to set disablesleep; not claiming a session.")
            isSleepDisabled = false
            sleepDisabledUntil = nil
            sessionOwner = nil
            Watchdog.shared.stop()
            return
        }

        // Crash safety net (pmset mode only): restore sleep if we're killed.
        if disabled {
            Watchdog.shared.start()
        } else {
            Watchdog.shared.stop()
        }
    }

    /// Returns true when the requested state is actually in effect.
    @discardableResult
    private func setSleepDisabledCaffeinate(_ enabled: Bool) async -> Bool {
        caffeinateProcess?.terminate()
        caffeinateProcess = nil

        guard enabled else { return true }

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
            sendNotification(
                title: "Could Not Enable Sleep Prevention",
                body: "Insomniac couldn't start caffeinate."
            )
            return false
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
                        self.clearSession()
                        self.sessionOwner = nil
                        self.sendNotification(
                            title: "Sleep Prevention Disabled",
                            body: "The caffeinate process ended unexpectedly."
                        )
                    }
                }
            }
        }

        // `terminationHandler` is only wired up after `run()`, so a process
        // that died in between would never report back. Catch that here.
        if !process.isRunning && process.terminationStatus != 0 {
            caffeinateProcess = nil
            logger.error("caffeinate exited immediately (status \(process.terminationStatus)).")
            return false
        }

        return true
    }
}
