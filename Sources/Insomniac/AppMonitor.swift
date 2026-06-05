import Foundation
import AppKit

/// Watches for specific apps to launch/terminate and notifies via callback.
final class AppMonitor {
    static let shared = AppMonitor()

    private var watchedBundleIDs: Set<String> = []
    private var onAnyWatchedRunning: (() -> Void)?
    private var onAllWatchedGone: (() -> Void)?

    private init() {}

    /// Returns true if any watched app is currently running.
    var isAnyWatchedAppRunning: Bool {
        runningWatchedBundleIDs().count > 0
    }

    /// Start monitoring. Calls `onAnyWatchedRunning` when a watched app launches,
    /// and `onAllWatchedGone` when all watched apps have terminated.
    func start(
        bundleIDs: Set<String>,
        onAnyWatchedRunning: @escaping () -> Void,
        onAllWatchedGone: @escaping () -> Void
    ) {
        self.watchedBundleIDs = bundleIDs
        self.onAnyWatchedRunning = onAnyWatchedRunning
        self.onAllWatchedGone = onAllWatchedGone

        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(
            self,
            selector: #selector(appDidLaunch(_:)),
            name: NSWorkspace.didLaunchApplicationNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(appDidTerminate(_:)),
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil
        )
    }

    func updateWatchedBundleIDs(_ bundleIDs: Set<String>) {
        let wasRunning = isAnyWatchedAppRunning
        watchedBundleIDs = bundleIDs
        let isRunning = isAnyWatchedAppRunning

        if !wasRunning && isRunning {
            onAnyWatchedRunning?()
        } else if wasRunning && !isRunning {
            onAllWatchedGone?()
        }
    }

    @objc private func appDidLaunch(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let bundleID = app.bundleIdentifier,
              watchedBundleIDs.contains(bundleID) else { return }
        onAnyWatchedRunning?()
    }

    @objc private func appDidTerminate(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let bundleID = app.bundleIdentifier,
              watchedBundleIDs.contains(bundleID) else { return }
        if !isAnyWatchedAppRunning {
            onAllWatchedGone?()
        }
    }

    private func runningWatchedBundleIDs() -> Set<String> {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier })
        return running.intersection(watchedBundleIDs)
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }
}
