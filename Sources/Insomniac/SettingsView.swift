import SwiftUI
import KeyboardShortcuts
import ServiceManagement

struct SettingsView: View {
    @State private var selectedTab = "general"

    // General Settings
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var startSessionOnLaunch = SleepManager.shared.startSessionOnLaunch
    @State private var quickStartToggleStyle = SleepManager.shared.quickStartToggleStyle
    @State private var useCaffeinate = SleepManager.shared.useCaffeinate
    @State private var requireCharging = SleepManager.shared.requireCharging
    @State private var thermalGuardEnabled = SleepManager.shared.thermalGuardEnabled
    @State private var thermalGuardCriticalOnly = SleepManager.shared.thermalGuardCriticalOnly
    @State private var batteryCutoffEnabled = SleepManager.shared.batteryCutoffEnabled
    @State private var batteryCutoffPercent = SleepManager.shared.batteryCutoffPercent
    @State private var autoCheckUpdates = UpdateChecker.autoCheckOnLaunch

    // Session Defaults
    @State private var defaultDuration: SleepManager.DurationOption = currentDefaultOption()
    @State private var autoDeactivate = SleepManager.shared.autoDeactivateOnSleep

    // Mouse Jiggler & Clicker Settings
    @State private var mouseJigglerEnabled = MouseManager.shared.isJigglerEnabled
    @State private var mouseClickerEnabled = MouseManager.shared.isClickerEnabled
    @State private var mouseJigglerInterval = MouseManager.shared.interval
    @State private var mouseJigglerInactivityDelay = MouseManager.shared.inactivityDelay
    @State private var mouseJigglerClickX = MouseManager.shared.clickX
    @State private var mouseJigglerClickY = MouseManager.shared.clickY
    @State private var mouseJigglerReturnCursor = MouseManager.shared.returnCursor
    @State private var mouseJigglerOnlyWhenIdle = MouseManager.shared.onlyWhenIdle
    @State private var mouseJigglerSpeed = MouseManager.shared.speed
    @State private var mouseJigglerClickType = MouseManager.shared.clickType
    @State private var isAccessibilityTrusted = AXIsProcessTrusted()

    // Triggers & Automation Settings
    @State private var watchedApps: [WatchedApp] = []
    @State private var scheduleEnabled = SleepManager.shared.scheduleEnabled
    @State private var scheduleStartHour = SleepManager.shared.scheduleStartHour
    @State private var scheduleStartMinute = SleepManager.shared.scheduleStartMinute
    @State private var scheduleEndHour = SleepManager.shared.scheduleEndHour
    @State private var scheduleEndMinute = SleepManager.shared.scheduleEndMinute
    @State private var scheduleDays = SleepManager.shared.scheduleDays
    @State private var activityBasedEnabled = SleepManager.shared.activityBasedEnabled
    @State private var activityThresholdPercent = SleepManager.shared.activityThresholdPercent
    @State private var activityIdleTimeout = SleepManager.shared.activityIdleTimeoutSeconds
    @State private var networkBasedEnabled = SleepManager.shared.networkBasedEnabled
    @State private var watchedNetworks = SleepManager.shared.watchedNetworks
    @State private var newNetworkName = ""
    @State private var dimOnBatteryOnly = SleepManager.shared.dimOnBatteryOnly
    @State private var skipDimOnExternalDisplay = SleepManager.shared.skipDimOnExternalDisplay
    @State private var downloadWatcherEnabled = SleepManager.shared.downloadWatcherEnabled
    @State private var downloadWatcherPath = SleepManager.shared.downloadWatcherPath

    struct WatchedApp {
        let bundleID: String
        let name: String
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            // Tab 1: General
            generalTab
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }
                .tag("general")

            // Tab 2: Session Defaults
            sessionDefaultsTab
                .tabItem {
                    Label("Session Defaults", systemImage: "clock")
                }
                .tag("defaults")

            // Tab 3: Cursor Controls
            cursorControlsTab
                .tabItem {
                    Label("Cursor", systemImage: "cursorarrow.motionlines")
                }
                .tag("cursor")

            // Tab 4: Triggers
            triggersTab
                .tabItem {
                    Label("Triggers", systemImage: "bolt.badge.a")
                }
                .tag("triggers")
        }
        .padding(20)
        .frame(minWidth: 480, minHeight: 450)
        .onAppear(perform: loadSettings)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            isAccessibilityTrusted = AXIsProcessTrusted()
        }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            loadSettings()
        }
    }

    // MARK: - Tab Views

    private var generalTab: some View {
        VStack(spacing: 16) {
            GroupBox(label: labelView("Launch & Window Behavior", systemImage: "macwindow")) {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Launch at login", isOn: $launchAtLogin)
                        .onChange(of: launchAtLogin) { _, newValue in
                            if newValue {
                                try? SMAppService.mainApp.register()
                            } else {
                                try? SMAppService.mainApp.unregister()
                            }
                        }

                    Toggle("Start session when Insomniac launches", isOn: $startSessionOnLaunch)
                        .onChange(of: startSessionOnLaunch) { _, newValue in
                            SleepManager.shared.startSessionOnLaunch = newValue
                        }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Quick-Start Toggle Style:")
                            .font(.caption)
                            .bold()
                        Picker("", selection: $quickStartToggleStyle) {
                            Text("Left-click toggles session (Right-click menu)").tag("leftClickToggle")
                            Text("Left-click opens menu (Right-click/Option-click toggles)").tag("leftClickMenu")
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .onChange(of: quickStartToggleStyle) { _, newValue in
                            SleepManager.shared.quickStartToggleStyle = newValue
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            GroupBox(label: labelView("Power Settings", systemImage: "battery.100")) {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Only enable sleep prevention while on AC power", isOn: $requireCharging)
                        .onChange(of: requireCharging) { _, newValue in
                            SleepManager.shared.requireCharging = newValue
                        }

                    Toggle("Use caffeinate mode (no sudo required)", isOn: $useCaffeinate)
                        .onChange(of: useCaffeinate) { _, newValue in
                            SleepManager.shared.useCaffeinate = newValue
                            if SleepManager.shared.isSleepDisabled {
                                Task { @MainActor in
                                    await SleepManager.shared.setSleepDisabled(false)
                                    if let dur = SleepManager.shared.remainingTime {
                                        SleepManager.shared.enableSleep(duration: dur)
                                    } else {
                                        SleepManager.shared.enableSleep(duration: nil)
                                    }
                                }
                            }
                        }
                    Text("Caffeinate mode prevents idle sleep only. It does not keep your Mac awake when the lid is closed.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            GroupBox(label: labelView("Safety", systemImage: "exclamationmark.shield")) {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Pause when the Mac runs hot", isOn: $thermalGuardEnabled)
                        .onChange(of: thermalGuardEnabled) { _, v in
                            SleepManager.shared.thermalGuardEnabled = v
                        }
                    Picker("Trip at:", selection: $thermalGuardCriticalOnly) {
                        Text("Serious heat").tag(false)
                        Text("Critical heat only").tag(true)
                    }
                    .pickerStyle(.menu)
                    .disabled(!thermalGuardEnabled)
                    .onChange(of: thermalGuardCriticalOnly) { _, v in
                        SleepManager.shared.thermalGuardCriticalOnly = v
                    }

                    Divider()

                    Toggle("Disable on low battery", isOn: $batteryCutoffEnabled)
                        .onChange(of: batteryCutoffEnabled) { _, v in
                            SleepManager.shared.batteryCutoffEnabled = v
                        }
                    Stepper("Cutoff: \(batteryCutoffPercent)%", value: $batteryCutoffPercent, in: 5...50, step: 5)
                        .disabled(!batteryCutoffEnabled)
                        .onChange(of: batteryCutoffPercent) { _, v in
                            SleepManager.shared.batteryCutoffPercent = v
                        }
                    Text("On battery, sleep prevention turns off at the cutoff and stays off until you re-enable it.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            GroupBox(label: labelView("Lid & Display", systemImage: "display")) {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Dim screen on lid close only while on battery", isOn: $dimOnBatteryOnly)
                        .onChange(of: dimOnBatteryOnly) { _, newValue in
                            SleepManager.shared.dimOnBatteryOnly = newValue
                        }
                    Toggle("Skip dimming when an external display is connected", isOn: $skipDimOnExternalDisplay)
                        .onChange(of: skipDimOnExternalDisplay) { _, newValue in
                            SleepManager.shared.skipDimOnExternalDisplay = newValue
                        }
                }
                .padding(.vertical, 4)
            }

            Spacer()

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Version \(versionString())")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Check for Updates...") { UpdateChecker.checkForUpdates(silent: false) }
                    }
                    Toggle("Check for updates automatically on launch", isOn: $autoCheckUpdates)
                        .onChange(of: autoCheckUpdates) { _, v in
                            UpdateChecker.autoCheckOnLaunch = v
                        }
                    Divider()
                    HStack {
                        Button("Welcome Guide...") { OnboardingManager.shared.show {} }
                        Spacer()
                        Button("Export...") { SettingsIO.exportSettings() }
                        Button("Import...") { SettingsIO.importSettings() }
                    }
                }
            }
        }
    }

    private var sessionDefaultsTab: some View {
        VStack(spacing: 16) {
            GroupBox(label: labelView("Session Defaults", systemImage: "clock.fill")) {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Default Duration Shortcut:", selection: $defaultDuration) {
                        Text("Indefinitely").tag(SleepManager.DurationOption.indefinite)
                        ForEach(SleepManager.DurationOption.presets) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .onChange(of: defaultDuration) { _, newValue in
                        SleepManager.shared.defaultDuration = newValue.seconds
                    }

                    Toggle("Auto-deactivate when device is put to sleep", isOn: $autoDeactivate)
                        .onChange(of: autoDeactivate) { _, newValue in
                            SleepManager.shared.autoDeactivateOnSleep = newValue
                        }
                }
                .padding(.vertical, 4)
            }

            GroupBox(label: labelView("Keyboard Shortcut", systemImage: "keyboard")) {
                VStack(alignment: .leading, spacing: 6) {
                    KeyboardShortcuts.Recorder("Global Activation Shortcut:", name: .toggleSleep)
                    Text("Default shortcut is ⌘⌥I. You can toggle sleep prevention globally from any application.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            Spacer()
        }
    }

    private var cursorControlsTab: some View {
        VStack(spacing: 14) {
            GroupBox(label: labelView("Cursor Movement Options", systemImage: "cursorarrow")) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 16) {
                        Toggle("Jiggle Cursor", isOn: $mouseJigglerEnabled)
                            .onChange(of: mouseJigglerEnabled) { _, newValue in
                                MouseManager.shared.isJigglerEnabled = newValue
                            }
                        Toggle("Enable Clicker", isOn: $mouseClickerEnabled)
                            .onChange(of: mouseClickerEnabled) { _, newValue in
                                MouseManager.shared.isClickerEnabled = newValue
                            }
                    }

                    Text("Cursor actions run only while sleep prevention is active. They start and stop with your session.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    if (mouseJigglerEnabled || mouseClickerEnabled) && !isAccessibilityTrusted {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("⚠️ Accessibility permissions required for cursor movements & clicks.")
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .bold()
                            Button("Grant Permission in Settings") {
                                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                            .buttonStyle(.borderless)
                            .font(.caption)
                        }
                        .padding(.top, 4)
                    }

                    if mouseJigglerEnabled || mouseClickerEnabled {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Trigger Interval:")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                            Picker("", selection: $mouseJigglerInterval) {
                                Text("10s").tag(10.0)
                                Text("30s").tag(30.0)
                                Text("1m").tag(60.0)
                                Text("5m").tag(300.0)
                                Text("15m").tag(900.0)
                            }
                            .pickerStyle(.segmented)
                            .onChange(of: mouseJigglerInterval) { _, newValue in
                                MouseManager.shared.interval = newValue
                            }
                        }
                        .padding(.vertical, 4)

                        Toggle("Only move/click when system is idle", isOn: $mouseJigglerOnlyWhenIdle)
                            .onChange(of: mouseJigglerOnlyWhenIdle) { _, newValue in
                                MouseManager.shared.onlyWhenIdle = newValue
                            }

                        if mouseJigglerOnlyWhenIdle {
                            HStack {
                                Text("Inactivity delay:")
                                    .font(.subheadline)
                                Slider(value: $mouseJigglerInactivityDelay, in: 5...300, step: 5)
                                    .onChange(of: mouseJigglerInactivityDelay) { _, newValue in
                                        MouseManager.shared.inactivityDelay = newValue
                                    }
                                Text(formatIdleTimeout(mouseJigglerInactivityDelay))
                                    .font(.system(.body, design: .monospaced))
                                    .frame(width: 60, alignment: .trailing)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.leading, 12)
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            if mouseJigglerEnabled || mouseClickerEnabled {
                GroupBox(label: labelView("Smart Motion Speed", systemImage: "speedometer")) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Interpolation Speed:")
                            Spacer()
                            Text(mouseJigglerSpeed >= 0.85 ? "Fast" : (mouseJigglerSpeed >= 0.45 ? "Medium" : "Slow"))
                                .foregroundStyle(.secondary)
                                .bold()
                        }
                        HStack(spacing: 12) {
                            Image(systemName: "tortoise.fill")
                                .foregroundColor(.secondary)
                            Slider(value: $mouseJigglerSpeed, in: 0.1...1.0, step: 0.05)
                                .onChange(of: mouseJigglerSpeed) { _, newValue in
                                    MouseManager.shared.speed = newValue
                                }
                            Image(systemName: "hare.fill")
                                .foregroundColor(.secondary)
                        }
                        Text("⚠️ Note: Slower mouse speeds require more CPU resources for step-by-step path rendering.")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                    .padding(.vertical, 4)
                }
            }

            if mouseClickerEnabled {
                GroupBox(label: labelView("Simulated Click Target", systemImage: "hand.tap")) {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("Click Action Type:", selection: $mouseJigglerClickType) {
                            Text("Left Click").tag("left")
                            Text("Right Click").tag("right")
                            Text("Middle Click").tag("middle")
                            Text("Double Click").tag("double")
                            Text("None (Move Only)").tag("none")
                        }
                        .onChange(of: mouseJigglerClickType) { _, newValue in
                            MouseManager.shared.clickType = newValue
                        }

                        if mouseJigglerClickType != "none" {
                            HStack {
                                Label {
                                    Text("X: \(Int(mouseJigglerClickX))  Y: \(Int(mouseJigglerClickY))")
                                        .font(.system(.body, design: .monospaced))
                                        .bold()
                                } icon: {
                                    Image(systemName: "scope")
                                        .foregroundColor(.orange)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.secondary.opacity(0.15))
                                .cornerRadius(6)

                                Spacer()
                                
                                Button {
                                    LocationPickerManager.shared.startPicking { point in
                                        mouseJigglerClickX = point.x
                                        mouseJigglerClickY = point.y
                                        MouseManager.shared.clickX = point.x
                                        MouseManager.shared.clickY = point.y
                                    }
                                } label: {
                                    Label("Select Location...", systemImage: "scope")
                                }
                            }
                            .padding(.vertical, 2)

                            Toggle("Return cursor to original location after click", isOn: $mouseJigglerReturnCursor)
                                .onChange(of: mouseJigglerReturnCursor) { _, newValue in
                                    MouseManager.shared.returnCursor = newValue
                                }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            Spacer()
        }
    }

    private var triggersTab: some View {
        ScrollView {
            VStack(spacing: 14) {
                // Schedule
                GroupBox(label: labelView("Schedule", systemImage: "calendar.badge.clock")) {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Keep awake on a weekly schedule", isOn: $scheduleEnabled)
                            .onChange(of: scheduleEnabled) { _, newValue in
                                SleepManager.shared.scheduleEnabled = newValue
                                SleepManager.shared.startSchedule()
                            }

                        if scheduleEnabled {
                            HStack(spacing: 6) {
                                ForEach(1...7, id: \.self) { day in
                                    let symbol = Calendar.current.veryShortWeekdaySymbols[day - 1]
                                    Toggle(symbol, isOn: Binding(
                                        get: { scheduleDays.contains(day) },
                                        set: { isOn in
                                            if isOn { scheduleDays.insert(day) } else { scheduleDays.remove(day) }
                                            SleepManager.shared.scheduleDays = scheduleDays
                                            SleepManager.shared.startSchedule()
                                        }
                                    ))
                                    .toggleStyle(.button)
                                }
                            }

                            HStack(spacing: 16) {
                                DatePicker("From:", selection: timeBinding(
                                    hour: $scheduleStartHour, minute: $scheduleStartMinute,
                                    onChange: { h, m in
                                        SleepManager.shared.scheduleStartHour = h
                                        SleepManager.shared.scheduleStartMinute = m
                                        SleepManager.shared.startSchedule()
                                    }
                                ), displayedComponents: .hourAndMinute)
                                DatePicker("To:", selection: timeBinding(
                                    hour: $scheduleEndHour, minute: $scheduleEndMinute,
                                    onChange: { h, m in
                                        SleepManager.shared.scheduleEndHour = h
                                        SleepManager.shared.scheduleEndMinute = m
                                        SleepManager.shared.startSchedule()
                                    }
                                ), displayedComponents: .hourAndMinute)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }

                // Activity-based
                GroupBox(label: labelView("Activity Detection", systemImage: "waveform.path.ecg")) {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Keep awake while the system is busy or in use", isOn: $activityBasedEnabled)
                            .onChange(of: activityBasedEnabled) { _, newValue in
                                SleepManager.shared.activityBasedEnabled = newValue
                                SleepManager.shared.startActivityMonitor()
                            }

                        if activityBasedEnabled {
                            HStack {
                                Text("CPU threshold:")
                                    .font(.subheadline)
                                Slider(value: Binding(
                                    get: { Double(activityThresholdPercent) },
                                    set: { newValue in
                                        activityThresholdPercent = Int(newValue)
                                        SleepManager.shared.activityThresholdPercent = Int(newValue)
                                    }
                                ), in: 5...95, step: 5)
                                Text("\(activityThresholdPercent)%")
                                    .font(.system(.body, design: .monospaced))
                                    .frame(width: 48, alignment: .trailing)
                                    .foregroundStyle(.secondary)
                            }
                            HStack {
                                Text("Idle timeout:")
                                    .font(.subheadline)
                                Slider(value: Binding(
                                    get: { Double(activityIdleTimeout) },
                                    set: { newValue in
                                        activityIdleTimeout = Int(newValue)
                                        SleepManager.shared.activityIdleTimeoutSeconds = Int(newValue)
                                    }
                                ), in: 30...900, step: 30)
                                Text(formatIdleTimeout(TimeInterval(activityIdleTimeout)))
                                    .font(.system(.body, design: .monospaced))
                                    .frame(width: 60, alignment: .trailing)
                                    .foregroundStyle(.secondary)
                            }
                            Text("Sleep prevention turns on when CPU exceeds the threshold or you are actively using the Mac, and off after the system stays idle.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }

                // Folder watcher
                GroupBox(label: labelView("File Download Watcher", systemImage: "arrow.down.circle")) {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Enable File Download Watcher", isOn: $downloadWatcherEnabled)
                            .onChange(of: downloadWatcherEnabled) { _, newValue in
                                SleepManager.shared.downloadWatcherEnabled = newValue
                            }

                        if downloadWatcherEnabled {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Watching Folder:")
                                    .font(.caption)
                                    .bold()
                                HStack {
                                    Text(downloadWatcherPath)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer()
                                    Button("Select Folder...") {
                                        selectDownloadFolder()
                                    }
                                }
                            }
                            .padding(.leading, 12)
                        }
                    }
                    .padding(.vertical, 4)
                }

                // Watched apps list
                GroupBox(label: labelView("Watched Applications", systemImage: "app")) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Keep awake while any of these applications are running:")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        ForEach(watchedApps, id: \.bundleID) { app in
                            HStack {
                                Image(systemName: "app.fill")
                                    .foregroundStyle(.secondary)
                                VStack(alignment: .leading) {
                                    Text(app.name)
                                        .font(.subheadline)
                                    Text(app.bundleID)
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                                Spacer()
                                Button {
                                    removeWatchedApp(app.bundleID)
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                        .foregroundStyle(.red)
                                }
                                .buttonStyle(.borderless)
                            }
                        }

                        Button("Add Application...") {
                            addWatchedApp()
                        }
                    }
                    .padding(.vertical, 4)
                }

                // Network WiFi based trigger
                GroupBox(label: labelView("WiFi Network Triggers", systemImage: "wifi")) {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Keep awake on selected Wi-Fi networks", isOn: $networkBasedEnabled)
                            .onChange(of: networkBasedEnabled) { _, newValue in
                                SleepManager.shared.networkBasedEnabled = newValue
                                SleepManager.shared.startNetworkMonitor()
                            }

                        if networkBasedEnabled {
                            HStack {
                                TextField("SSID / WiFi Name", text: $newNetworkName)
                                    .textFieldStyle(.roundedBorder)
                                    .onSubmit(addNetwork)
                                Button("Add") { addNetwork() }
                                    .disabled(newNetworkName.trimmingCharacters(in: .whitespaces).isEmpty)
                            }

                            ForEach(watchedNetworks, id: \.self) { network in
                                HStack {
                                    Image(systemName: "wifi")
                                        .foregroundStyle(.secondary)
                                    Text(network)
                                    Spacer()
                                    Button {
                                        removeNetwork(network)
                                    } label: {
                                        Image(systemName: "minus.circle.fill")
                                            .foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    // MARK: - Helpers

    private func timeBinding(
        hour: Binding<Int>,
        minute: Binding<Int>,
        onChange: @escaping (Int, Int) -> Void
    ) -> Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(
                    bySettingHour: hour.wrappedValue,
                    minute: minute.wrappedValue,
                    second: 0,
                    of: Date()
                ) ?? Date()
            },
            set: { newDate in
                let components = Calendar.current.dateComponents([.hour, .minute], from: newDate)
                hour.wrappedValue = components.hour ?? 0
                minute.wrappedValue = components.minute ?? 0
                onChange(components.hour ?? 0, components.minute ?? 0)
            }
        )
    }

    private func labelView(_ text: String, systemImage: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .foregroundStyle(Color.accentColor)
            Text(text)
                .font(.headline)
        }
    }

    private func loadSettings() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
        startSessionOnLaunch = SleepManager.shared.startSessionOnLaunch
        quickStartToggleStyle = SleepManager.shared.quickStartToggleStyle
        autoDeactivate = SleepManager.shared.autoDeactivateOnSleep
        useCaffeinate = SleepManager.shared.useCaffeinate
        requireCharging = SleepManager.shared.requireCharging
        thermalGuardEnabled = SleepManager.shared.thermalGuardEnabled
        thermalGuardCriticalOnly = SleepManager.shared.thermalGuardCriticalOnly
        batteryCutoffEnabled = SleepManager.shared.batteryCutoffEnabled
        batteryCutoffPercent = SleepManager.shared.batteryCutoffPercent
        autoCheckUpdates = UpdateChecker.autoCheckOnLaunch
        defaultDuration = Self.currentDefaultOption()
        loadWatchedApps()
        scheduleEnabled = SleepManager.shared.scheduleEnabled
        scheduleStartHour = SleepManager.shared.scheduleStartHour
        scheduleStartMinute = SleepManager.shared.scheduleStartMinute
        scheduleEndHour = SleepManager.shared.scheduleEndHour
        scheduleEndMinute = SleepManager.shared.scheduleEndMinute
        scheduleDays = SleepManager.shared.scheduleDays
        activityBasedEnabled = SleepManager.shared.activityBasedEnabled
        activityThresholdPercent = SleepManager.shared.activityThresholdPercent
        activityIdleTimeout = SleepManager.shared.activityIdleTimeoutSeconds
        networkBasedEnabled = SleepManager.shared.networkBasedEnabled
        watchedNetworks = SleepManager.shared.watchedNetworks
        dimOnBatteryOnly = SleepManager.shared.dimOnBatteryOnly
        skipDimOnExternalDisplay = SleepManager.shared.skipDimOnExternalDisplay
        
        downloadWatcherEnabled = SleepManager.shared.downloadWatcherEnabled
        downloadWatcherPath = SleepManager.shared.downloadWatcherPath

        mouseJigglerEnabled = MouseManager.shared.isJigglerEnabled
        mouseClickerEnabled = MouseManager.shared.isClickerEnabled
        mouseJigglerInterval = MouseManager.shared.interval
        mouseJigglerInactivityDelay = MouseManager.shared.inactivityDelay
        mouseJigglerClickX = MouseManager.shared.clickX
        mouseJigglerClickY = MouseManager.shared.clickY
        mouseJigglerReturnCursor = MouseManager.shared.returnCursor
        mouseJigglerOnlyWhenIdle = MouseManager.shared.onlyWhenIdle
        mouseJigglerSpeed = MouseManager.shared.speed
        mouseJigglerClickType = MouseManager.shared.clickType
        isAccessibilityTrusted = AXIsProcessTrusted()
    }

    private func selectDownloadFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "Select Watch Folder"
        panel.message = "Choose the folder you want to watch for active downloads."
        
        guard panel.runModal() == .OK, let url = panel.url else { return }
        downloadWatcherPath = url.path
        SleepManager.shared.downloadWatcherPath = url.path
    }

    private func loadWatchedApps() {
        let bundleIDs = SleepManager.shared.watchedAppBundleIDs
        watchedApps = bundleIDs.map { bundleID in
            let name = appName(for: bundleID) ?? bundleID
            return WatchedApp(bundleID: bundleID, name: name)
        }
    }

    private func appName(for bundleID: String) -> String? {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return nil
    }

    private func addWatchedApp() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = "Choose an App"
        panel.message = "Select an app to watch. When this app is running, Insomniac will automatically prevent sleep."

        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let bundle = Bundle(url: url), let bundleID = bundle.bundleIdentifier else {
            showAlert(title: "Could not read app", message: "The selected file is not a valid app bundle.")
            return
        }

        var current = SleepManager.shared.watchedAppBundleIDs
        guard !current.contains(bundleID) else { return }
        current.append(bundleID)
        SleepManager.shared.watchedAppBundleIDs = current
        SleepManager.shared.updateWatchedApps()
        loadWatchedApps()
    }

    private func removeWatchedApp(_ bundleID: String) {
        var current = SleepManager.shared.watchedAppBundleIDs
        current.removeAll { $0 == bundleID }
        SleepManager.shared.watchedAppBundleIDs = current
        SleepManager.shared.updateWatchedApps()
        loadWatchedApps()
    }

    private func addNetwork() {
        let trimmed = newNetworkName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        var current = SleepManager.shared.watchedNetworks
        if !current.contains(trimmed) {
            current.append(trimmed)
            SleepManager.shared.watchedNetworks = current
            watchedNetworks = current
        }
        newNetworkName = ""
    }

    private func removeNetwork(_ ssid: String) {
        var current = SleepManager.shared.watchedNetworks
        current.removeAll { $0 == ssid }
        SleepManager.shared.watchedNetworks = current
        watchedNetworks = current
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func versionString() -> String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }

    private static func currentDefaultOption() -> SleepManager.DurationOption {
        let current = SleepManager.shared.defaultDuration
        if let current,
           let match = SleepManager.DurationOption.presets.first(where: { $0.seconds == current }) {
            return match
        }
        return .indefinite
    }

    private func formatIdleTimeout(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        if total < 60 {
            return "\(total)s"
        } else {
            let mins = total / 60
            let secs = total % 60
            if secs > 0 {
                return "\(mins)m \(secs)s"
            } else {
                return "\(mins)m"
            }
        }
    }
}
