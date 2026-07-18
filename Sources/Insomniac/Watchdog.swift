import Foundation
import OSLog

/// Crash safety net for pmset mode. If the app is force-killed while the hard
/// `disablesleep` flag is set, the Mac stays awake until reboot. A detached
/// `/bin/sh` loop — reparented to launchd when we die — restores sleep using the
/// existing passwordless `sudo pmset` grant, so no privileged helper is needed.
@MainActor
final class Watchdog {
    static let shared = Watchdog()

    private let logger = Logger(subsystem: "com.insomniac.app", category: "Watchdog")
    private var process: Process?

    /// Stale threshold (90s) must exceed the app's beat interval (30s).
    private let staleSeconds = 90
    private let pollSeconds = 30

    private var heartbeatPath: String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Insomniac", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("heartbeat").path
    }

    private init() {}

    /// Spawn the watchdog and write the first heartbeat. Idempotent.
    func start() {
        guard process == nil else { beat(); return }
        let hb = heartbeatPath
        beat()

        let script = """
        HB="\(hb)"
        while sleep \(pollSeconds); do
          m=$(stat -f %m "$HB" 2>/dev/null) || exit 0
          now=$(date +%s)
          if [ $((now - m)) -gt \(staleSeconds) ]; then
            /usr/bin/sudo -n /usr/bin/pmset -a disablesleep 0
            exit 0
          fi
        done
        """

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", script]
        do {
            try proc.run()
            process = proc
        } catch {
            logger.error("Failed to launch watchdog: \(error.localizedDescription)")
        }
    }

    /// Refresh the heartbeat mtime; call while sleep is disabled.
    func beat() {
        let hb = heartbeatPath
        if !FileManager.default.fileExists(atPath: hb) {
            FileManager.default.createFile(atPath: hb, contents: nil)
        }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: hb)
    }

    /// Graceful stop: remove the heartbeat (watchdog exits on next poll) and
    /// terminate the child. Restoring an already-restored flag is harmless.
    func stop() {
        try? FileManager.default.removeItem(atPath: heartbeatPath)
        process?.terminate()
        process = nil
    }
}
