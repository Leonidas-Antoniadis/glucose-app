import Foundation

/// Append-only on-device store: one JSON-lines file per UTC day.
///
/// Small, crash-tolerant writes (one line per reading) and cheap range loads. On iOS the
/// directory inherits the app's data protection and is excluded from iCloud backup by the app.
public final class ReadingArchive: @unchecked Sendable {
    public let directory: URL
    private let fileManager = FileManager.default
    private let lock = NSLock()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    public init(directory: URL) throws {
        self.directory = directory
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func fileURL(for date: Date) -> URL {
        directory.appendingPathComponent("readings-\(Self.dayFormatter.string(from: date)).jsonl")
    }

    public func append(_ readings: [GlucoseReading]) throws {
        guard !readings.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        let grouped = Dictionary(grouping: readings) { fileURL(for: $0.timestamp) }
        for (url, dayReadings) in grouped {
            var data = Data()
            for reading in dayReadings {
                data.append(try encoder.encode(reading))
                data.append(0x0A)
            }
            try appendData(data, to: url)
        }
    }

    /// Appends lines to a day file. If an earlier write was cut short (storage full), the file
    /// ends with half a line: a newline first keeps the new lines from being glued onto it.
    private func appendData(_ data: Data, to url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else {
            try data.write(to: url, options: .atomic)
            return
        }
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let end = try handle.seekToEnd()
        var prefix = Data()
        if end > 0 {
            try handle.seek(toOffset: end - 1)
            if handle.readData(ofLength: 1) != Data([0x0A]) { prefix.append(0x0A) }
            try handle.seekToEnd()
        }
        try handle.write(contentsOf: prefix + data)
    }

    /// Loads readings in the interval, deduplicated (live beats backfill) and sorted.
    public func load(from start: Date, to end: Date) throws -> [GlucoseReading] {
        lock.lock()
        defer { lock.unlock() }
        var readings: [GlucoseReading] = []
        // Never walk more than ~2 years of day files.
        for url in dayFiles(from: max(start, end.addingTimeInterval(-730 * 86_400)), through: end) {
            guard let data = try? Data(contentsOf: url) else { continue }
            for line in data.split(separator: 0x0A) where !line.isEmpty {
                if let reading = try? decoder.decode(GlucoseReading.self, from: Data(line)),
                   reading.timestamp >= start, reading.timestamp <= end {
                    readings.append(reading)
                }
            }
        }
        return ReadingPipeline.merge([], with: readings)
    }

    /// The day files covering `start...end`. File names are UTC days, so this walks UTC days in
    /// fixed 24-hour steps: stepping by local calendar days skips a whole file at a DST change.
    private func dayFiles(from start: Date, through end: Date) -> [URL] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        var urls: [URL] = []
        var day = calendar.startOfDay(for: start)
        while day <= end {
            urls.append(fileURL(for: day))
            day = day.addingTimeInterval(86_400)
        }
        return urls
    }

    /// Re-dates one sensor's stored readings from its minute counter (see `ReadingPipeline.retimed`)
    /// and rewrites the day files they are in. A sensor lives at most about 15 days, so only the
    /// files from two days before `activatedAt` to two days after `end` are touched.
    public func retime(sensorSerial: String, activatedAt: Date, through end: Date) throws {
        try rewrite(sensorSerial: sensorSerial, from: activatedAt.addingTimeInterval(-2 * 86_400),
                    through: max(end, activatedAt).addingTimeInterval(2 * 86_400)) { reading in
            reading.retimed(to: activatedAt.addingTimeInterval(Double(reading.minuteIndex) * 60))
        }
    }

    /// Recomputes one sensor's stored readings from `since` on with a new calibration (see
    /// `ReadingPipeline.recalibrated`), so values loaded later match what the screen showed.
    public func recalibrate(sensorSerial: String, since: Date, calibration: Calibration) throws {
        try rewrite(sensorSerial: sensorSerial, from: since, through: Date().addingTimeInterval(86_400)) { reading in
            reading.timestamp >= since ? (reading.recalibrated(with: calibration) ?? reading) : reading
        }
    }

    /// Rewrites the day files from `start` to `end` that hold readings of one sensor, passing each
    /// of that sensor's readings through `transform`. Other readings stay as they are.
    private func rewrite(sensorSerial: String, from start: Date, through end: Date,
                         transform: (GlucoseReading) -> GlucoseReading) throws {
        lock.lock()
        defer { lock.unlock() }
        let urls = Array(dayFiles(from: start, through: end).prefix(40))

        var kept: [GlucoseReading] = []
        var touchedFiles: [URL] = []
        var changed = false
        for url in urls {
            guard let data = try? Data(contentsOf: url) else { continue }
            let readings = data.split(separator: 0x0A).compactMap { try? decoder.decode(GlucoseReading.self, from: Data($0)) }
            guard readings.contains(where: { $0.sensorSerial == sensorSerial }) else { continue }
            touchedFiles.append(url)
            for reading in readings {
                if reading.sensorSerial == sensorSerial {
                    let updated = transform(reading)
                    if updated != reading { changed = true }
                    kept.append(updated)
                } else {
                    kept.append(reading)
                }
            }
        }
        guard changed else { return }

        var contents: [URL: Data] = [:]
        for reading in kept {
            contents[fileURL(for: reading.timestamp), default: Data()].append(try encoder.encode(reading))
            contents[fileURL(for: reading.timestamp), default: Data()].append(0x0A)
        }
        for url in touchedFiles where contents[url] == nil {
            try? fileManager.removeItem(at: url)
        }
        for (url, data) in contents {
            if touchedFiles.contains(url) {
                try data.write(to: url, options: .atomic)
            } else {
                // A reading moved into a day file this pass didn't read: add to it.
                try appendData(data, to: url)
            }
        }
    }

    /// Deletes day files that end before `date`.
    public func prune(olderThan date: Date) throws {
        lock.lock()
        defer { lock.unlock() }
        let cutoff = Self.dayFormatter.string(from: date)
        for name in try fileManager.contentsOfDirectory(atPath: directory.path)
        where name.hasPrefix("readings-") && name.hasSuffix(".jsonl") {
            let day = String(name.dropFirst("readings-".count).dropLast(".jsonl".count))
            if day < cutoff {
                try fileManager.removeItem(at: directory.appendingPathComponent(name))
            }
        }
    }

    /// Removes everything (used by "Delete all data").
    public func removeAll() throws {
        lock.lock()
        defer { lock.unlock() }
        for name in try fileManager.contentsOfDirectory(atPath: directory.path) {
            try fileManager.removeItem(at: directory.appendingPathComponent(name))
        }
    }
}

/// Small Codable value stored as one JSON file (settings, sensor, logbook).
public struct JSONFileStore<Value: Codable> {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func load() -> Value? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Value.self, from: data)
    }

    public func save(_ value: Value) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
    }

    public func delete() {
        try? FileManager.default.removeItem(at: url)
    }
}
