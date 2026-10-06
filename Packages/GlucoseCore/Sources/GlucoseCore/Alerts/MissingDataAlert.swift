import Foundation

/// Alert that fires when no reading has arrived for N minutes.
///
/// The app cancels and reschedules local notifications at the dates returned by
/// `fireDates(...)` on every new reading. Because they are scheduled with iOS ahead of time,
/// they still fire if iOS kills the app, so a dead app can't silently stop alerting.
public struct MissingDataAlert: Codable, Hashable, Sendable {
    public static let allowedMinutes: ClosedRange<Int> = 5...180
    /// iOS allows 64 pending local notifications per app; keep plenty in reserve.
    public static let maxScheduledNotifications = 12

    public var isEnabled: Bool
    public var minutes: Int {
        didSet { minutes = min(max(minutes, Self.allowedMinutes.lowerBound), Self.allowedMinutes.upperBound) }
    }
    public var sound: SoundStyle
    public var isCritical: Bool
    /// Repeat every N minutes while data is still missing. nil = alert once.
    public var repeatIntervalMinutes: Int?
    public var schedule: AlertSchedule
    /// Don't alert during the sensor's warm-up period.
    public var suppressDuringWarmUp: Bool
    /// Grace period after an app restart or Bluetooth toggle.
    public var graceMinutesAfterRestart: Int

    public init(
        isEnabled: Bool = true,
        minutes: Int = 15,
        sound: SoundStyle = .tune(name: "chime"),
        isCritical: Bool = false,
        repeatIntervalMinutes: Int? = 15,
        schedule: AlertSchedule = .always,
        suppressDuringWarmUp: Bool = true,
        graceMinutesAfterRestart: Int = 5
    ) {
        self.isEnabled = isEnabled
        self.minutes = min(max(minutes, Self.allowedMinutes.lowerBound), Self.allowedMinutes.upperBound)
        self.sound = sound
        self.isCritical = isCritical
        self.repeatIntervalMinutes = repeatIntervalMinutes
        self.schedule = schedule
        self.suppressDuringWarmUp = suppressDuringWarmUp
        self.graceMinutesAfterRestart = graceMinutesAfterRestart
    }

    /// Dates at which "no data" notifications should fire, given the last reading time.
    /// - Parameters:
    ///   - warmUpEnds: end of sensor warm-up, if a sensor is warming up.
    ///   - restartedAt: last app restart / Bluetooth toggle, for the grace period.
    public func fireDates(
        lastReading: Date,
        warmUpEnds: Date? = nil,
        restartedAt: Date? = nil,
        calendar: Calendar = .current
    ) -> [Date] {
        guard isEnabled else { return [] }
        var first = lastReading.addingTimeInterval(Double(minutes) * 60)
        if suppressDuringWarmUp, let warmUpEnds {
            first = max(first, warmUpEnds.addingTimeInterval(Double(minutes) * 60))
        }
        if let restartedAt {
            first = max(first, restartedAt.addingTimeInterval(Double(graceMinutesAfterRestart) * 60))
        }

        var dates = [first]
        if let interval = repeatIntervalMinutes, interval > 0 {
            for index in 1..<Self.maxScheduledNotifications {
                dates.append(first.addingTimeInterval(Double(index * interval) * 60))
            }
        }
        return dates.filter { schedule.isActive(at: $0, calendar: calendar) }
    }

    /// The notification text for one fire date: how long data has really been missing by then,
    /// not just the first delay (the 01:00 repeat says 3 h, not 15 min).
    public static func message(firingAt date: Date, lastReading: Date) -> String {
        let minutes = max(1, Int((date.timeIntervalSince(lastReading) / 60).rounded()))
        let elapsed: String
        if minutes < 60 {
            elapsed = "\(minutes) min"
        } else if minutes % 60 == 0 {
            elapsed = "\(minutes / 60) h"
        } else {
            elapsed = "\(minutes / 60) h \(minutes % 60) min"
        }
        return "No reading for \(elapsed). Check the sensor and Bluetooth."
    }
}

/// Lifecycle of a Libre 2 Plus sensor.
public enum SensorLifecycle {
    public static let warmUpMinutes = 60
    public static let lifetimeDays = 15

    public static func warmUpEnds(startedAt: Date) -> Date {
        startedAt.addingTimeInterval(Double(warmUpMinutes) * 60)
    }

    public static func expires(startedAt: Date) -> Date {
        startedAt.addingTimeInterval(Double(lifetimeDays) * 24 * 3600)
    }
}
