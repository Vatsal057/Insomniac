import Foundation
import AppKit
import UniformTypeIdentifiers

/// Manages export/import of Insomniac settings as a portable plist file.
enum SettingsIO {
    private static let keys: [String] = [
        "autoDeactivateOnSleep",
        "defaultSleepDurationSeconds",
        "useCaffeinateMode",
        "requireCharging",
        "watchedAppBundleIDs",
        "watchedNetworks",
        "scheduleEnabled",
        "scheduleStartHour",
        "scheduleStartMinute",
        "scheduleEndHour",
        "scheduleEndMinute",
        "scheduleDays",
        "activityBasedEnabled",
        "activityThresholdPercent",
        "dimOnBatteryOnly",
        "skipDimOnExternalDisplay"
    ]

    static func exportSettings() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.propertyList]
        panel.nameFieldStringValue = "Insomniac-Settings.plist"
        panel.canCreateDirectories = true
        panel.title = "Export Insomniac Settings"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        var dict: [String: Any] = [:]
        for key in keys {
            if let value = UserDefaults.standard.object(forKey: key) {
                dict[key] = value
            }
        }

        do {
            let data = try PropertyListSerialization.data(
                fromPropertyList: dict,
                format: .xml,
                options: 0
            )
            try data.write(to: url)

            let alert = NSAlert()
            alert.messageText = "Settings Exported"
            alert.informativeText = "Your settings have been saved to \(url.lastPathComponent)."
            alert.addButton(withTitle: "OK")
            alert.runModal()
        } catch {
            showError("Failed to export settings: \(error.localizedDescription)")
        }
    }

    static func importSettings() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.propertyList]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.title = "Import Insomniac Settings"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let data = try Data(contentsOf: url)
            guard let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
                showError("The selected file is not a valid Insomniac settings file.")
                return
            }

            for (key, value) in plist {
                UserDefaults.standard.set(value, forKey: key)
            }

            let alert = NSAlert()
            alert.messageText = "Settings Imported"
            alert.informativeText = "Your settings have been restored. Some changes may require restarting Insomniac."
            alert.addButton(withTitle: "OK")
            alert.runModal()
        } catch {
            showError("Failed to import settings: \(error.localizedDescription)")
        }
    }

    private static func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Error"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
