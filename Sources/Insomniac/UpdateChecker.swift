import Foundation
import AppKit

/// Checks GitHub Releases for a newer version. No Sparkle, no auto-install —
/// it just points the user at the download page.
@MainActor
enum UpdateChecker {
    static let repo = "Vatsal057/Insomniac"

    private static let autoCheckKey = "autoCheckUpdatesOnLaunch"
    static var autoCheckOnLaunch: Bool {
        get { UserDefaults.standard.object(forKey: autoCheckKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: autoCheckKey) }
    }

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    /// `silent`: only surface UI when a newer version exists (used at launch).
    /// Otherwise also report "up to date" and network errors (menu command).
    static func checkForUpdates(silent: Bool) {
        Task {
            do {
                let (latest, url) = try await fetchLatest()
                if compareVersions(latest, currentVersion) > 0 {
                    presentUpdate(latest: latest, url: url)
                } else if !silent {
                    presentAlert(title: "You're up to date",
                                 body: "Insomniac \(currentVersion) is the latest version.")
                }
            } catch {
                if !silent {
                    presentAlert(title: "Update check failed",
                                 body: error.localizedDescription)
                }
            }
        }
    }

    private struct Release: Decodable {
        let tag_name: String
        let html_url: String
    }

    private static func fetchLatest() async throws -> (version: String, url: String) {
        let api = URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!
        var request = URLRequest(url: api)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        let release = try JSONDecoder().decode(Release.self, from: data)
        let version = release.tag_name.hasPrefix("v")
            ? String(release.tag_name.dropFirst())
            : release.tag_name
        return (version, release.html_url)
    }

    /// Numeric dotted-version compare. Returns >0 if `a` newer than `b`, 0 equal,
    /// <0 older. Non-numeric or missing components count as 0 (`1.10` > `1.9`).
    static func compareVersions(_ a: String, _ b: String) -> Int {
        let lhs = a.split(separator: ".").map { Int($0) ?? 0 }
        let rhs = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(lhs.count, rhs.count) {
            let l = i < lhs.count ? lhs[i] : 0
            let r = i < rhs.count ? rhs[i] : 0
            if l != r { return l < r ? -1 : 1 }
        }
        return 0
    }

    private static func presentUpdate(latest: String, url: String) {
        let alert = NSAlert()
        alert.messageText = "Update available"
        alert.informativeText = "Insomniac \(latest) is available. You have \(currentVersion)."
        alert.icon = NSImage(systemSymbolName: "arrow.down.circle.fill", accessibilityDescription: nil)
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn, let link = URL(string: url) {
            NSWorkspace.shared.open(link)
        }
    }

    private static func presentAlert(title: String, body: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    #if DEBUG
    /// Runnable self-check for the pure compare (asserts on launch in Debug).
    static func selfCheck() {
        assert(compareVersions("1.10", "1.9") > 0)
        assert(compareVersions("1.9", "1.10") < 0)
        assert(compareVersions("1.0", "1.0") == 0)
        assert(compareVersions("2.0", "1.9.9") > 0)
        assert(compareVersions("1.0.1", "1.0") > 0)
    }
    #endif
}
