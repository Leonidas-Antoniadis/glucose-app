import Foundation
import GlucoseCore

struct AppSettings: Codable {
    var unit: GlucoseUnit
    var ruleSet: AlertRuleSet
    var missingData: MissingDataAlert
}

/// On-device storage only. Files are protected until first unlock and excluded from iCloud backup.
struct LocalStore {
    private var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    private var settingsURL: URL { directory.appendingPathComponent("settings.json") }

    func loadSettings() -> AppSettings? {
        guard let data = try? Data(contentsOf: settingsURL) else { return nil }
        return try? JSONDecoder().decode(AppSettings.self, from: data)
    }

    func saveSettings(_ settings: AppSettings) throws {
        try write(JSONEncoder().encode(settings), to: settingsURL)
    }

    private func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        try mutableURL.setResourceValues(values)
    }
}
