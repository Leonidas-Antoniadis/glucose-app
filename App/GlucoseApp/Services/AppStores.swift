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
    /// The alert engine's memory (snoozes, repeats, decision log), so a relaunch doesn't reset it.
    let alertState: JSONFileStore<AlertEngine.Snapshot>
    /// The alert decision log, kept apart from the alert state so it survives a change of data source.
    let decisionLog: JSONFileStore<[String]>
    /// Bluetooth link quality per hour and its outages, for the signal report.
    let signalStats: JSONFileStore<SignalStats>
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
        // Serials and notes for support calls; erased by "Delete all data" too.
        sensorHistory = JSONFileStore(url: directory.appendingPathComponent("sensor-history.json"))
        savedCaptures = JSONFileStore(url: directory.appendingPathComponent("saved-captures.json"))
        alertState = JSONFileStore(url: directory.appendingPathComponent("alert-state.json"))
        decisionLog = JSONFileStore(url: directory.appendingPathComponent("decision-log.json"))
        signalStats = JSONFileStore(url: directory.appendingPathComponent("signal-stats.json"))
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
        alertState.delete()
        decisionLog.delete()
        signalStats.delete()
        try? FileManager.default.removeItem(at: capturesURL)
        Self.clearExports()
    }

    /// Where reports, backups and capture files are written for the share sheet. One folder, so
    /// "Delete all data" and the next launch can remove every copy left behind.
    static var exportsDirectory: URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Exports", isDirectory: true)
        // Files made here are readable only while the phone is unlocked.
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                 attributes: [.protectionKey: FileProtectionType.complete])
        return url
    }

    /// Removes exports older than `age` seconds, when the app leaves the screen: long enough for
    /// a share in progress to finish, short enough that a CSV of every reading doesn't stay for
    /// weeks while the app keeps running in the background.
    static func clearExports(olderThan age: TimeInterval) {
        let fileManager = FileManager.default
        let folder = fileManager.temporaryDirectory.appendingPathComponent("Exports", isDirectory: true)
        let files = (try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in files {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if Date().timeIntervalSince(modified) > age { try? fileManager.removeItem(at: file) }
        }
    }

    static func clearExports() {
        let fileManager = FileManager.default
        let tmp = fileManager.temporaryDirectory
        try? fileManager.removeItem(at: tmp.appendingPathComponent("Exports", isDirectory: true))
        // Versions up to 0.2 wrote them straight into tmp.
        let legacy = ["Glucose report ", "Glucose data ", "Glucose backup ", "Libre captures"]
        for name in (try? fileManager.contentsOfDirectory(atPath: tmp.path)) ?? [] where legacy.contains(where: name.hasPrefix) {
            try? fileManager.removeItem(at: tmp.appendingPathComponent(name))
        }
    }
}
