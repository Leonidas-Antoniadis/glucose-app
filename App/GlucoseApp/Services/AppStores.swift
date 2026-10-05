import Foundation
import GlucoseCore
import LibreProtocol

/// All on-device files. They live in Application Support/GlucoseData, which is protected
/// until first unlock (the iOS default) and excluded from iCloud backup.
struct AppStores {
    let directory: URL
    let settings: JSONFileStore<AppSettings>
    let sensor: JSONFileStore<LibreSensorRecord>
    let logbook: JSONFileStore<[LogEntry]>
    let fingersticks: JSONFileStore<[FingerstickEntry]>
    let sensorHistory: JSONFileStore<SensorHistory>
    let savedCaptures: JSONFileStore<[SavedCapture]>
    let archive: ReadingArchive?
    let capturesURL: URL

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directory = support.appendingPathComponent("GlucoseData", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var excluded = directory
        try? excluded.setResourceValues(values)

        settings = JSONFileStore(url: directory.appendingPathComponent("settings.json"))
        sensor = JSONFileStore(url: directory.appendingPathComponent("sensor.json"))
        logbook = JSONFileStore(url: directory.appendingPathComponent("logbook.json"))
        fingersticks = JSONFileStore(url: directory.appendingPathComponent("fingersticks.json"))
        // Kept on "Delete all data", since it's what support asks for.
        sensorHistory = JSONFileStore(url: directory.appendingPathComponent("sensor-history.json"))
        savedCaptures = JSONFileStore(url: directory.appendingPathComponent("saved-captures.json"))
        archive = try? ReadingArchive(directory: directory.appendingPathComponent("readings", isDirectory: true))
        capturesURL = directory.appendingPathComponent("captures.log")

        // Version 0.1 kept settings directly in Application Support.
        let legacy = support.appendingPathComponent("settings.json")
        if settings.load() == nil, let old = JSONFileStore<AppSettings>(url: legacy).load() {
            var migrated = old
            migrated.onboardingDone = true
            try? settings.save(migrated)
            try? FileManager.default.removeItem(at: legacy)
        }
    }

    /// Appends a line to the capture log (raw sensor bytes for offline debugging).
    func appendCapture(_ line: String) {
        let data = Data((line + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: capturesURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: capturesURL, options: .atomic)
        }
    }

    /// Drops capture log lines older than `cutoff`. Each line starts with an ISO 8601 UTC time,
    /// so comparing the text compares the dates.
    func pruneCaptures(olderThan cutoff: Date) {
        guard let text = try? String(contentsOf: capturesURL, encoding: .utf8) else { return }
        let oldest = ISO8601DateFormatter().string(from: cutoff)
        let lines = text.split(separator: "\n")
        let kept = lines.filter { String($0.prefix(oldest.count)) >= oldest }
        guard kept.count < lines.count else { return }
        if kept.isEmpty {
            try? FileManager.default.removeItem(at: capturesURL)
        } else {
            try? Data((kept.joined(separator: "\n") + "\n").utf8).write(to: capturesURL, options: .atomic)
        }
    }

    func deleteEverything() {
        try? archive?.removeAll()
        sensor.delete()
        logbook.delete()
        fingersticks.delete()
        savedCaptures.delete()
        try? FileManager.default.removeItem(at: capturesURL)
    }
}
