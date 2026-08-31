import Foundation
import OSLog

/// Crash safety net for pmset mode.
///
/// The hard `disablesleep` flag lives in the system, not in this app. If the app
/// is force-killed while it's set, the Mac stays awake until reboot. So a small
/// detached `/bin/sh` — reparented to launchd when we die — clears the flag using
/// the existing passwordless `sudo pmset` grant. No privileged helper needed.
///
/// **How it detects death, and why it costs nothing.**
///
/// The child inherits the read end of a pipe this process holds open, and blocks
/// on `read`. A blocking read is free: the process is parked in the kernel,
/// consuming no CPU and scheduling no wake-ups. When this process exits — for
/// any reason, including `kill -9` — the kernel closes our write end, the read
/// returns end-of-file, and the child restores sleep immediately.
///
/// The previous design polled instead: the app rewrote a heartbeat file every
/// 30 seconds and the child woke every 30 seconds to compare its timestamp.
/// That was two timers running for the entire session, and it reacted up to 90
/// seconds late. This reacts instantly and idles at zero.
///
/// A clean quit calls `stop()`, which terminates the child before the pipe
/// closes, so a normal shutdown never triggers the restore.
@MainActor
final class Watchdog {
    static let shared = Watchdog()

    private let logger = Logger(subsystem: "com.insomniac.app", category: "Watchdog")
    private var process: Process?
    /// Our end of the pipe. Holding it open is what keeps the child blocked;
    /// releasing it is the death signal.
    private var lifeline: Pipe?

    private init() {}

    /// Spawn the watchdog. Idempotent.
    func start() {
        guard process == nil else { return }

        // Blocks with no CPU until our write end closes, then restores sleep.
        // `head -c 1` reads a single byte or EOF and exits either way; using a
        // shell builtin would depend on `read` semantics across shells.
        let script = """
        /usr/bin/head -c 1 >/dev/null 2>&1
        /usr/bin/sudo -n /usr/bin/pmset -a disablesleep 0
        """

        let pipe = Pipe()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", script]
        proc.standardInput = pipe
        // Don't inherit our stdout/stderr; a detached child writing to a closed
        // descriptor after we exit is a needless failure mode.
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice

        do {
            try proc.run()
            process = proc
            lifeline = pipe
        } catch {
            logger.error("Failed to launch watchdog: \(error.localizedDescription)")
        }
    }

    /// Graceful stop: kill the child before it can observe the pipe closing, so
    /// it exits without touching pmset. The app has already restored sleep
    /// itself by this point.
    func stop() {
        guard let proc = process else {
            lifeline = nil
            return
        }
        process = nil
        proc.terminate()
        // Release our end only after the child is signalled, so the ordering
        // can't race into a spurious restore.
        lifeline = nil
    }
}
