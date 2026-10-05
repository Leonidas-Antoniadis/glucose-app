import Foundation

public enum AlertDirection: String, Codable, CaseIterable, Sendable {
    case low
    case high
}

/// How a rule sounds. Tunes and voice clips are bundled audio files (iOS limit: 30 s).
public enum SoundStyle: Codable, Hashable, Sendable {
    case silent
    case tune(name: String)
    case voice(clip: String)
}

/// Days and time window in which a rule is allowed to alert.
public struct AlertSchedule: Codable, Hashable, Sendable {
    /// Calendar weekdays (1 = Sunday ... 7 = Saturday).
    public var weekdays: Set<Int>
    /// Minutes after midnight. If `endMinute <= startMinute` the window wraps past midnight
    /// (e.g. 22:00-07:00); `startMinute == endMinute` means the whole day.
    public var startMinute: Int
    public var endMinute: Int

    public init(weekdays: Set<Int> = Set(1...7), startMinute: Int = 0, endMinute: Int = 0) {
        self.weekdays = weekdays
        self.startMinute = startMinute
        self.endMinute = endMinute
    }

    public static let always = AlertSchedule()
    public static let nightOnly = AlertSchedule(startMinute: 22 * 60, endMinute: 7 * 60)

    public func isActive(at date: Date, calendar: Calendar = .current) -> Bool {
        let parts = calendar.dateComponents([.hour, .minute, .weekday], from: date)
        guard let hour = parts.hour, let minute = parts.minute, let weekday = parts.weekday else { return false }
        let minuteOfDay = hour * 60 + minute

        if startMinute == endMinute {
            return weekdays.contains(weekday)
        }
        if startMinute < endMinute {
            return weekdays.contains(weekday) && minuteOfDay >= startMinute && minuteOfDay < endMinute
        }
        // Wrapping window: the part after midnight belongs to the previous day's window.
        if minuteOfDay >= startMinute {
            return weekdays.contains(weekday)
        }
        if minuteOfDay < endMinute {
            let previousDay = weekday == 1 ? 7 : weekday - 1
            return weekdays.contains(previousDay)
        }
        return false
    }
}

/// One user-configurable threshold alert.
public struct AlertRule: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var direction: AlertDirection
    public var isEnabled: Bool
    public var thresholdMgdL: Double
    public var sound: SoundStyle
    /// Critical Alert: sounds through Silent mode and Focus (needs Apple's entitlement).
    public var isCritical: Bool
    /// Critical Alert volume, 0...1.
    public var criticalVolume: Double
    /// Repeat while unacknowledged, every N minutes. nil = no repeats.
    public var repeatIntervalMinutes: Int?
    /// Maximum number of repeats. nil = until acknowledged.
    public var maxRepeats: Int?
    public var snoozeMinutes: Int
    public var schedule: AlertSchedule
    /// Only alert once the value has been past the threshold for this long (avoids compression lows).
    public var confirmationMinutes: Int
    /// Hysteresis: the rule re-arms only after the value recovers past threshold +/- this margin.
    public var rearmMarginMgdL: Double

    public init(
        id: UUID = UUID(),
        name: String,
        direction: AlertDirection,
        isEnabled: Bool = true,
        thresholdMgdL: Double,
        sound: SoundStyle,
        isCritical: Bool = false,
        criticalVolume: Double = 1.0,
        repeatIntervalMinutes: Int? = 5,
        maxRepeats: Int? = nil,
        snoozeMinutes: Int = 30,
        schedule: AlertSchedule = .always,
        confirmationMinutes: Int = 0,
        rearmMarginMgdL: Double = 5
    ) {
        self.id = id
        self.name = name
        self.direction = direction
        self.isEnabled = isEnabled
        self.thresholdMgdL = thresholdMgdL
        self.sound = sound
        self.isCritical = isCritical
        self.criticalVolume = criticalVolume
        self.repeatIntervalMinutes = repeatIntervalMinutes
        self.maxRepeats = maxRepeats
        self.snoozeMinutes = snoozeMinutes
        self.schedule = schedule
        self.confirmationMinutes = confirmationMinutes
        self.rearmMarginMgdL = rearmMarginMgdL
    }

    /// True while the value is past the threshold (strictly below a low, strictly above a high).
    public func isCrossed(by mgdL: Double) -> Bool {
        switch direction {
        case .low: return mgdL < thresholdMgdL
        case .high: return mgdL > thresholdMgdL
        }
    }

    /// True once the value has recovered far enough for the rule to re-arm.
    public func hasRecovered(at mgdL: Double) -> Bool {
        switch direction {
        case .low: return mgdL >= thresholdMgdL + rearmMarginMgdL
        case .high: return mgdL <= thresholdMgdL - rearmMarginMgdL
        }
    }

    /// Whether this rule is more severe than another rule in the same direction.
    public func isMoreSevere(than other: AlertRule) -> Bool {
        switch direction {
        case .low: return thresholdMgdL < other.thresholdMgdL
        case .high: return thresholdMgdL > other.thresholdMgdL
        }
    }
}
