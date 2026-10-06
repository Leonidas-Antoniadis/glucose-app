import Foundation

/// Day / night split and per-day overlays for reports.
public enum DailyPatterns {
    public static let dayStartHour = 6
    public static let nightStartHour = 22

    /// Statistics for daytime (06:00-22:00) and night (22:00-06:00) readings.
    public static func dayNight(_ readings: [GlucoseReading], period: DateInterval, calendar: Calendar = .current)
        -> (day: GlucoseStatistics?, night: GlucoseStatistics?) {
        var day: (values: [Double], minutes: [Double]) = ([], [])
        var night: (values: [Double], minutes: [Double]) = ([], [])
        let inPeriod = readings.filter { period.contains($0.timestamp) }.sorted { $0.timestamp < $1.timestamp }
        // Weighted by the time each reading covers, like the overall statistics.
        for (reading, minutes) in zip(inPeriod, ReadingPipeline.timeWeights(inPeriod)) {
            let hour = calendar.component(.hour, from: reading.timestamp)
            if hour >= dayStartHour && hour < nightStartHour {
                day.values.append(reading.mgdL)
                day.minutes.append(minutes)
            } else {
                night.values.append(reading.mgdL)
                night.minutes.append(minutes)
            }
        }
        // Expected minutes scale with the share of the day each window covers.
        let totalMinutes = period.duration / 60
        let dayShare = Double(nightStartHour - dayStartHour) / 24
        return (
            GlucoseStatistics(values: day.values, minutes: day.minutes, expectedMinutes: totalMinutes * dayShare),
            GlucoseStatistics(values: night.values, minutes: night.minutes, expectedMinutes: totalMinutes * (1 - dayShare))
        )
    }

    public struct DaySeries: Hashable, Sendable, Identifiable {
        public var id: Date { day }
        /// Start of the calendar day.
        public let day: Date
        /// (minutes after midnight, mg/dL), sorted by time.
        public let points: [Point]

        public struct Point: Hashable, Sendable {
            public let minuteOfDay: Int
            public let mgdL: Double
        }
    }

    /// Splits readings into calendar days for an overlay chart, thinning to one point per `stepMinutes`.
    public static func overlay(_ readings: [GlucoseReading], stepMinutes: Int = 5, calendar: Calendar = .current) -> [DaySeries] {
        let byDay = Dictionary(grouping: readings) { calendar.startOfDay(for: $0.timestamp) }
        return byDay.keys.sorted().map { day in
            var seenBuckets = Set<Int>()
            let points = (byDay[day] ?? [])
                .sorted { $0.timestamp < $1.timestamp }
                .compactMap { reading -> DaySeries.Point? in
                    let parts = calendar.dateComponents([.hour, .minute], from: reading.timestamp)
                    let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
                    guard seenBuckets.insert(minute / stepMinutes).inserted else { return nil }
                    return DaySeries.Point(minuteOfDay: minute, mgdL: reading.mgdL)
                }
            return DaySeries(day: day, points: points)
        }
    }
}

public extension SensorLifecycle {
    struct Reminder: Hashable, Sendable {
        public let date: Date
        public let title: String
        public let body: String
    }

    /// Notifications before and at the end of a sensor's life.
    static func reminders(expiresAt: Date, now: Date) -> [Reminder] {
        [
            Reminder(date: expiresAt.addingTimeInterval(-24 * 3600), title: "Sensor ends tomorrow",
                     body: "Your sensor ends in 24 hours. Have a new one ready."),
            Reminder(date: expiresAt.addingTimeInterval(-2 * 3600), title: "Sensor ends in 2 hours",
                     body: "Apply a new sensor soon to avoid a gap in readings."),
            Reminder(date: expiresAt, title: "Sensor ended",
                     body: "This sensor has ended. Start a new one with LibreLink, then pair it here."),
        ].filter { $0.date > now }
    }
}
