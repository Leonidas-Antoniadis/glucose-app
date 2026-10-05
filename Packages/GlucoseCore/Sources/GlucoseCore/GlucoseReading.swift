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
}

public enum ReadingPipeline {
    /// Values outside this range are treated as sensor errors, not glucose.
    public static let plausibleRangeMgdL: ClosedRange<Double> = 20...600

    public static func isPlausible(_ reading: GlucoseReading) -> Bool {
        reading.mgdL.isFinite && plausibleRangeMgdL.contains(reading.mgdL)
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

    private static func priority(of source: GlucoseReading.Source) -> Int {
        switch source {
        case .bluetooth: return 3
        case .nfc: return 2
        case .backfill: return 1
        case .simulated: return 0
        }
    }
}
