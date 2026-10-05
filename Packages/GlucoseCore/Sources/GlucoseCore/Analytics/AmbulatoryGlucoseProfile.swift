import Foundation

/// Ambulatory Glucose Profile: percentiles of glucose by time of day across many days.
public struct AmbulatoryGlucoseProfile: Hashable, Sendable {
    public struct Bin: Hashable, Sendable {
        /// Start of the bin, in minutes after midnight.
        public let minuteOfDay: Int
        public let count: Int
        public let p5: Double
        public let p25: Double
        public let median: Double
        public let p75: Double
        public let p95: Double
    }

    public let binMinutes: Int
    /// Only bins that contain data, ordered by time of day.
    public let bins: [Bin]

    public init(readings: [GlucoseReading], binMinutes: Int = 15, calendar: Calendar = .current) {
        precondition(binMinutes > 0 && (24 * 60) % binMinutes == 0, "binMinutes must divide a day")
        self.binMinutes = binMinutes

        var grouped: [Int: [Double]] = [:]
        for reading in readings {
            let parts = calendar.dateComponents([.hour, .minute], from: reading.timestamp)
            let minuteOfDay = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            grouped[minuteOfDay / binMinutes * binMinutes, default: []].append(reading.mgdL)
        }

        bins = grouped.keys.sorted().compactMap { key in
            guard let values = grouped[key]?.sorted(), !values.isEmpty else { return nil }
            return Bin(
                minuteOfDay: key,
                count: values.count,
                p5: Self.percentile(values, 0.05),
                p25: Self.percentile(values, 0.25),
                median: Self.percentile(values, 0.50),
                p75: Self.percentile(values, 0.75),
                p95: Self.percentile(values, 0.95)
            )
        }
    }

    /// Percentile of already-sorted values, with linear interpolation between ranks.
    public static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return .nan }
        let rank = p * Double(sorted.count - 1)
        let lower = Int(rank.rounded(.down))
        let upper = min(lower + 1, sorted.count - 1)
        let weight = rank - Double(lower)
        return sorted[lower] + (sorted[upper] - sorted[lower]) * weight
    }
}
