import Foundation
import Network

/// Monitors the current Wi-Fi SSID and notifies via callback on changes.
/// Uses `networksetup` shell command for SSID lookup (works on modern macOS
/// without requiring location permission).
final class NetworkMonitor {
    static let shared = NetworkMonitor()

    private var monitor: NWPathMonitor?
    private let monitorQueue = DispatchQueue(label: "com.insomniac.networkmonitor")

    private var onChange: ((String?) -> Void)?
    private var lastSSID: String?
    private var pollTimer: Timer?

    private init() {}

    /// Returns the current Wi-Fi SSID, or nil if not connected to Wi-Fi.
    /// Tries each Wi-Fi interface reported by `networksetup -listallhardwareports`
    /// and returns the first one that has an active SSID.
    private var cachedInterfaces: [String]?

    var currentSSID: String? {
        let interfaces = listWiFiInterfaces()
        for interface in interfaces {
            if let ssid = ssidForInterface(interface) {
                return ssid
            }
        }
        return nil
    }

    func fetchCurrentSSID() async -> String? {
        await Task.detached(priority: .utility) { [weak self] in
            guard let self else { return nil }
            let interfaces = self.listWiFiInterfaces()
            for interface in interfaces {
                if let ssid = self.ssidForInterface(interface) {
                    return ssid
                }
            }
            return nil
        }.value
    }

    private func listWiFiInterfaces() -> [String] {
        if let cached = cachedInterfaces { return cached }

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
            return ["en0"]
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
        let result = interfaces.isEmpty ? ["en0"] : interfaces
        cachedInterfaces = result
        return result
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

        if let range = output.range(of: ": "),
           let newlineRange = output[range.upperBound...].range(of: "\n") {
            let ssid = String(output[range.upperBound..<newlineRange.lowerBound])
            return ssid.isEmpty ? nil : ssid
        }
        return nil
    }

    func start(onChange: @escaping (String?) -> Void) {
        stop()
        self.onChange = onChange

        let newMonitor = NWPathMonitor()
        newMonitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                await self.pollAndNotify()
            }
        }
        newMonitor.start(queue: monitorQueue)
        monitor = newMonitor

        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.pollAndNotify()
            }
        }

        Task { @MainActor in
            await self.pollAndNotify()
        }
    }

    @MainActor
    private func pollAndNotify() async {
        let ssid = await fetchCurrentSSID()
        if ssid != lastSSID {
            lastSSID = ssid
            onChange?(ssid)
        }
    }

    func stop() {
        monitor?.cancel()
        monitor = nil
        pollTimer?.invalidate()
        pollTimer = nil
    }

    deinit {
        stop()
    }
}
