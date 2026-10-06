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
            if fileManager.fileExists(atPath: url.path) {
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: url, options: .atomic)
            }
        }
    }

    /// Loads readings in the interval, deduplicated (live beats backfill) and sorted.
    public func load(from start: Date, to end: Date) throws -> [GlucoseReading] {
        lock.lock()
        defer { lock.unlock() }
        var readings: [GlucoseReading] = []
        // Never walk more than ~2 years of day files.
        var day = max(start, end.addingTimeInterval(-730 * 86_400))
        let calendar = Self.dayFormatter.calendar!
        var visited = Set<URL>()
        while day <= end.addingTimeInterval(86_400) {
            let url = fileURL(for: day)
            if visited.insert(url).inserted, let data = try? Data(contentsOf: url) {
                for line in data.split(separator: 0x0A) where !line.isEmpty {
                    if let reading = try? decoder.decode(GlucoseReading.self, from: Data(line)),
                       reading.timestamp >= start, reading.timestamp <= end {
                        readings.append(reading)
                    }
                }
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return ReadingPipeline.merge([], with: readings)
    }

    /// Re-dates one sensor's stored readings from its minute counter (see `ReadingPipeline.retimed`)
    /// and rewrites the day files they are in. A sensor lives at most about 15 days, so only the
    /// files from two days before `activatedAt` to two days after `end` are touched.
    public func retime(sensorSerial: String, activatedAt: Date, through end: Date) throws {
        lock.lock()
        defer { lock.unlock() }
        // Step in fixed 24-hour steps from a UTC instant: file names are UTC days.
        var urls: [URL] = []
        var day = activatedAt.addingTimeInterval(-2 * 86_400)
        let last = max(end, activatedAt).addingTimeInterval(2 * 86_400)
        while day <= last, urls.count < 40 {
            let url = fileURL(for: day)
            if !urls.contains(url) { urls.append(url) }
            day = day.addingTimeInterval(86_400)
        }

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
                    let timestamp = activatedAt.addingTimeInterval(Double(reading.minuteIndex) * 60)
                    if timestamp != reading.timestamp { changed = true }
                    kept.append(reading.retimed(to: timestamp))
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
            if touchedFiles.contains(url) || !fileManager.fileExists(atPath: url.path) {
                try data.write(to: url, options: .atomic)
            } else {
                // A reading moved into a day file this pass didn't read: add to it.
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
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
