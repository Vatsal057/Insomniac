import Foundation
import Network

/// Monitors the current Wi-Fi SSID and notifies via callback on changes.
/// Uses `networksetup` shell command for SSID lookup (works on modern macOS
/// without requiring location permission).
final class NetworkMonitor {
    static let shared = NetworkMonitor()

    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "com.insomniac.networkmonitor")

    private var onChange: ((String?) -> Void)?
    private var lastSSID: String?
    private var pollTimer: Timer?

    private init() {}

    /// Returns the current Wi-Fi SSID, or nil if not connected to Wi-Fi.
    /// Tries each Wi-Fi interface reported by `networksetup -listallhardwareports`
    /// and returns the first one that has an active SSID.
    var currentSSID: String? {
        let interfaces = listWiFiInterfaces()
        for interface in interfaces {
            if let ssid = ssidForInterface(interface) {
                return ssid
            }
        }
        return nil
    }

    private func listWiFiInterfaces() -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        process.arguments = ["-listallhardwareports"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return ["en0"]  // sensible default
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else {
            return ["en0"]
        }

        var interfaces: [String] = []
        var currentType: String?
        let lines = output.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("Hardware Port:") {
                currentType = trimmed.replacingOccurrences(of: "Hardware Port: ", with: "")
            } else if trimmed.hasPrefix("Device:") {
                let device = trimmed.replacingOccurrences(of: "Device: ", with: "")
                if let type = currentType, type.lowercased().contains("wi-fi") {
                    interfaces.append(device)
                }
            }
        }
        return interfaces.isEmpty ? ["en0"] : interfaces
    }

    private func ssidForInterface(_ interface: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        process.arguments = ["-getairportnetwork", interface]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return nil }

        // Output: "Current Wi-Fi Network: MyNetwork\n" or "You are not associated with an AirPort network.\n"
        if let range = output.range(of: ": "),
           let newlineRange = output[range.upperBound...].range(of: "\n") {
            let ssid = String(output[range.upperBound..<newlineRange.lowerBound])
            return ssid.isEmpty ? nil : ssid
        }
        return nil
    }

    /// Start monitoring. The callback fires on the main queue with the current SSID
    /// (or nil if not on Wi-Fi) whenever the network changes.
    func start(onChange: @escaping (String?) -> Void) {
        self.onChange = onChange

        // Detect network path changes (Wi-Fi join/leave)
        monitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                // Small delay to let Wi-Fi association settle
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                self.pollAndNotify()
            }
        }
        monitor.start(queue: monitorQueue)

        // Poll every 30s as a safety net (network state can change without
        // NWPathMonitor firing — e.g. switching to same BSSID)
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pollAndNotify()
            }
        }

        // Fire immediately
        Task { @MainActor in
            self.pollAndNotify()
        }
    }

    @MainActor
    private func pollAndNotify() {
        let ssid = currentSSID
        if ssid != lastSSID {
            lastSSID = ssid
            onChange?(ssid)
        }
    }

    func stop() {
        monitor.cancel()
        pollTimer?.invalidate()
        pollTimer = nil
    }

    deinit {
        stop()
    }
}
