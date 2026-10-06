import Foundation

/// One glucose value from a sensor.
public struct GlucoseReading: Codable, Hashable, Sendable, Identifiable {
    public enum Source: String, Codable, Sendable {
        case bluetooth   // live 1-minute value
        case backfill    // history block received after a reconnect
        case nfc         // manual scan
        case simulated   // demo / development data
    }

    /// Unique per sensor and minute, so the same minute can never be stored twice.
    public var id: String { "\(sensorSerial)#\(minuteIndex)" }

    public let sensorSerial: String
    /// Minutes since the sensor was started. Sensor time is the deduplication key.
    public let minuteIndex: Int
    public let timestamp: Date
    public let mgdL: Double
    public let source: Source
    /// Uncalibrated sensor signal, kept so values can be recalculated after calibration.
    public let raw: Double?

    public init(sensorSerial: String, minuteIndex: Int, timestamp: Date, mgdL: Double, source: Source, raw: Double? = nil) {
        self.sensorSerial = sensorSerial
        self.minuteIndex = minuteIndex
        self.timestamp = timestamp
        self.mgdL = mgdL
        self.source = source
        self.raw = raw
    }

    /// Shown as LO: the sensor's value was at or below `ReadingPipeline.lowMgdL`.
    public var isBelowRange: Bool { mgdL <= ReadingPipeline.lowMgdL }
    /// Shown as HI: the sensor's value was at or above `ReadingPipeline.highMgdL`.
    public var isAboveRange: Bool { mgdL >= ReadingPipeline.highMgdL }

    /// The same reading with another timestamp.
    public func retimed(to timestamp: Date) -> GlucoseReading {
        GlucoseReading(sensorSerial: sensorSerial, minuteIndex: minuteIndex, timestamp: timestamp, mgdL: mgdL,
                       source: source, raw: raw)
    }
}

public enum ReadingPipeline {
    /// Values below this are stored as this value and shown as LO, like Abbott's devices do.
    public static let lowMgdL: Double = 39
    /// Values above this are stored as this value and shown as HI.
    public static let highMgdL: Double = 501
    /// Anything outside this range is not glucose (a broken value), so it is dropped.
    public static let plausibleRangeMgdL: ClosedRange<Double> = 1...1000

    public static func isPlausible(_ reading: GlucoseReading) -> Bool {
        reading.mgdL.isFinite && plausibleRangeMgdL.contains(reading.mgdL)
    }

    /// A computed glucose value clamped to LO...HI, or nil if it isn't a number at all.
    /// A very low value must still reach the alerts: dropping it would stop urgent-low repeats
    /// exactly when glucose is lowest.
    public static func clamped(_ mgdL: Double) -> Double? {
        guard mgdL.isFinite else { return nil }
        return min(max(mgdL, lowMgdL), highMgdL)
    }

    /// Merges new readings into an existing series: drops implausible values,
    /// deduplicates by sensor + minute (a live value wins over a backfilled one)
    /// and returns the result sorted by time.
    public static func merge(_ existing: [GlucoseReading], with incoming: [GlucoseReading]) -> [GlucoseReading] {
        var byID: [String: GlucoseReading] = [:]
        for reading in existing + incoming where isPlausible(reading) {
            if let current = byID[reading.id] {
                if priority(of: reading.source) > priority(of: current.source) {
                    byID[reading.id] = reading
                }
            } else {
                byID[reading.id] = reading
            }
        }
        return byID.values.sorted { $0.timestamp < $1.timestamp }
    }

    /// Re-dates one sensor's readings from its minute counter (`activatedAt` + `minuteIndex` minutes),
    /// for when the sensor's start time had to be moved because the phone clock changed or drifted.
    /// Without this, new readings would sort before older ones dated by the old clock.
    public static func retimed(_ readings: [GlucoseReading], sensorSerial: String, activatedAt: Date) -> [GlucoseReading] {
        readings
            .map { $0.sensorSerial == sensorSerial ? $0.retimed(to: activatedAt.addingTimeInterval(Double($0.minuteIndex) * 60)) : $0 }
            .sorted { $0.timestamp < $1.timestamp }
    }

    /// Returns the gaps (in minutes of sensor time) inside a single sensor's series.
    public static func gaps(in readings: [GlucoseReading], sensorSerial: String) -> [ClosedRange<Int>] {
        let minutes = readings
            .filter { $0.sensorSerial == sensorSerial }
            .map(\.minuteIndex)
            .sorted()
        var result: [ClosedRange<Int>] = []
        for (previous, next) in zip(minutes, minutes.dropFirst()) where next - previous > 1 {
            result.append((previous + 1)...(next - 1))
        }
        return result
    }

    /// The most recent stretch without readings that's longer than `minimumMinutes`, looking back
    /// `lookbackHours` from `now`. A gap that reaches up to `now` counts too (data has stopped).
    public static func recentGap(in readings: [GlucoseReading], now: Date, minimumMinutes: Double = 20,
                                 lookbackHours: Double = 24) -> DateInterval? {
        let start = now.addingTimeInterval(-lookbackHours * 3600)
        let times = readings.map(\.timestamp).filter { $0 >= start && $0 <= now }.sorted()
        guard let last = times.last else { return nil }
        if now.timeIntervalSince(last) > minimumMinutes * 60 {
            return DateInterval(start: last, end: now)
        }
        for (earlier, later) in zip(times, times.dropFirst()).reversed() where later.timeIntervalSince(earlier) > minimumMinutes * 60 {
            return DateInterval(start: earlier, end: later)
        }
        return nil
    }

    private static func priority(of source: GlucoseReading.Source) -> Int {
        switch source {
        case .bluetooth: return 3
        case .nfc: return 2
        case .backfill: return 1
        case .simulated: return 0
        }
    }
}
