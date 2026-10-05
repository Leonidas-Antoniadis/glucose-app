import Foundation
@testable import GlucoseCore

enum TestSupport {
    static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// Monday 2026-01-05 12:00 UTC.
    static let noon = Date(timeIntervalSince1970: 1_767_614_400)

    static func reading(_ mgdL: Double, minute: Int, start: Date = noon, source: GlucoseReading.Source = .bluetooth) -> GlucoseReading {
        GlucoseReading(sensorSerial: "TEST", minuteIndex: minute,
                       timestamp: start.addingTimeInterval(Double(minute) * 60), mgdL: mgdL, source: source)
    }
}
