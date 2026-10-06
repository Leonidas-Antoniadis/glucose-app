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

    /// The same reading with another glucose value.
    public func withValue(_ mgdL: Double) -> GlucoseReading {
        GlucoseReading(sensorSerial: sensorSerial, minuteIndex: minuteIndex, timestamp: timestamp, mgdL: mgdL,
                       source: source, raw: raw)
    }

    /// The value recomputed from the raw signal with another calibration (nil without a raw value).
    public func recalibrated(with calibration: Calibration) -> GlucoseReading? {
        guard let raw, let mgdL = ReadingPipeline.clamped(calibration.mgdL(fromRaw: raw).rounded()) else { return nil }
        return withValue(mgdL)
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

    /// Recomputes one sensor's readings from `since` on with a new calibration. Values from before
    /// a calibration would otherwise sit next to values from after it, and the step between them
    /// reads as a fast rise or fall (false arrows and "Low soon" alerts).
    public static func recalibrated(_ readings: [GlucoseReading], sensorSerial: String, since: Date,
                                    calibration: Calibration) -> [GlucoseReading] {
        readings.map { reading in
            guard reading.sensorSerial == sensorSerial, reading.timestamp >= since else { return reading }
            return reading.recalibrated(with: calibration) ?? reading
        }
    }

    /// The minutes each reading stands for: the gap to the next reading, up to `maxMinutes` (the
    /// spacing of the sensor's 15-minute history). A longer gap is missing data, not coverage, so
    /// the reading before it counts as one minute. The last reading takes the weight before it.
    /// Statistics weighted this way count a 15-minute history value 15 times as much as a
    /// 1-minute live value. `readings` must be sorted by time.
    public static func timeWeights(_ readings: [GlucoseReading], maxMinutes: Double = 16) -> [Double] {
        guard readings.count > 1 else { return readings.map { _ in 1 } }
        var weights: [Double] = []
        weights.reserveCapacity(readings.count)
        for (current, next) in zip(readings, readings.dropFirst()) {
            let gap = max(next.timestamp.timeIntervalSince(current.timestamp) / 60, 0)
            weights.append(gap <= maxMinutes ? gap : 1)
        }
        weights.append(weights.last ?? 1)
        return weights
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
