import Foundation
import OSLog

/// Calls a closure when a folder's contents change, using zero CPU in between.
///
/// The kernel already tracks directory changes, so `DispatchSource`'s vnode
/// support can hand them over as events. Nothing runs until the folder actually
/// changes — no timer, no wake-ups, no periodic `contentsOfDirectory` scan.
///
/// Two details worth knowing:
///
/// - Events are coalesced with a short debounce. A browser writing a large file
///   can touch its directory entry many times in a second, and there's no point
///   re-listing the folder for each one.
/// - A vnode watch follows the *inode*, not the path. If the folder is deleted,
///   renamed, or replaced, the watch dies with it — so a `.delete`/`.rename`
///   event tears down and re-opens the watch by path.
@MainActor
final class FolderWatcher {
    private let logger = Logger(subsystem: "com.insomniac.app", category: "FolderWatcher")

    private let path: String
    private let onChange: () -> Void

    private var source: DispatchSourceFileSystemObject?
    private var descriptor: CInt = -1
    private var debounce: DispatchWorkItem?

    /// How long to wait for a burst of writes to settle.
    private static let debounceInterval: TimeInterval = 0.75
    /// Backoff before re-opening a folder that vanished, so a deleted folder
    /// can't turn into a reopen loop.
    private static let reopenDelay: TimeInterval = 2.0

    init(path: String, onChange: @escaping () -> Void) {
        self.path = path
        self.onChange = onChange
        open()
    }

    deinit {
        // `source.cancel()` closes the descriptor via the cancel handler set in
        // `open()`, so there's nothing to close here.
        debounce?.cancel()
        source?.cancel()
    }

    private func open() {
        close()

        // O_EVTONLY: open purely to observe. It doesn't count as a reference
        // that would stop the volume being unmounted.
        let fd = Darwin.open(path, O_EVTONLY)
        guard fd >= 0 else {
            logger.error("Couldn't watch \(self.path, privacy: .private): errno \(errno)")
            return
        }
        descriptor = fd

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .revoke],
            queue: .main
        )

        source.setEventHandler { [weak self] in
            guard let self else { return }
            let flags = self.source?.data ?? []
            if flags.contains(.delete) || flags.contains(.rename) || flags.contains(.revoke) {
                // The folder we were holding is gone. Re-resolve the path.
                self.scheduleReopen()
            } else {
                self.scheduleCallback()
            }
        }

        // Runs on cancel *and* on deinit — the one place the fd is closed, so it
        // can't be closed twice or leaked.
        source.setCancelHandler { [fd] in
            Darwin.close(fd)
        }

        self.source = source
        source.resume()
    }

    private func close() {
        debounce?.cancel()
        debounce = nil
        source?.cancel()   // cancel handler closes the descriptor
        source = nil
        descriptor = -1
    }

    /// Coalesces a burst of writes into one callback.
    private func scheduleCallback() {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.debounce = nil
            self.onChange()
        }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.debounceInterval, execute: work)
    }

    private func scheduleReopen() {
        close()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.reopenDelay) { [weak self] in
            guard let self else { return }
            guard FileManager.default.fileExists(atPath: self.path) else { return }
            self.open()
            self.onChange()
        }
    }
}
