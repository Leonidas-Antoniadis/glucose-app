import Foundation

/// Alerts based on the direction of travel rather than a fixed threshold.
public struct TrendAlert: Codable, Hashable, Identifiable, Sendable {
    public enum Kind: Codable, Hashable, Sendable {
        /// Fires when the 15-minute trend projects a value below the threshold within `minutesAhead`.
        case predictiveLow(thresholdMgdL: Double, minutesAhead: Int)
        /// Fires when glucose falls faster than this rate (mg/dL per minute, positive number).
        case fallingFast(mgdLPerMinute: Double)
        /// Fires when glucose rises faster than this rate (mg/dL per minute).
        case risingFast(mgdLPerMinute: Double)

        public var direction: AlertDirection {
            switch self {
            case .predictiveLow, .fallingFast: return .low
            case .risingFast: return .high
            }
        }
    }

    public var id: UUID
    public var name: String
    public var kind: Kind
    public var isEnabled: Bool
    public var sound: SoundStyle
    public var isCritical: Bool
    public var snoozeMinutes: Int
    public var schedule: AlertSchedule

    public init(id: UUID = UUID(), name: String, kind: Kind, isEnabled: Bool = true, sound: SoundStyle,
                isCritical: Bool = false, snoozeMinutes: Int = 30, schedule: AlertSchedule = .always) {
        self.id = id
        self.name = name
        self.kind = kind
        self.isEnabled = isEnabled
        self.sound = sound
        self.isCritical = isCritical
        self.snoozeMinutes = snoozeMinutes
        self.schedule = schedule
    }

    public static func defaults() -> [TrendAlert] {
        [
            TrendAlert(name: "Low soon", kind: .predictiveLow(thresholdMgdL: 70, minutesAhead: 20),
                       sound: .voice(clip: "low_soon")),
            TrendAlert(name: "Falling fast", kind: .fallingFast(mgdLPerMinute: 2), isEnabled: false,
                       sound: .voice(clip: "falling_fast")),
            TrendAlert(name: "Rising fast", kind: .risingFast(mgdLPerMinute: 2), isEnabled: false,
                       sound: .voice(clip: "rising_fast")),
        ]
    }

    /// Condition check for the latest value, 15-minute rate and projection.
    func isTriggered(value: Double, rate: Double?, projected: Double?) -> Bool {
        switch kind {
        case .predictiveLow(let threshold, _):
            guard let projected else { return false }
            return value >= threshold && projected < threshold
        case .fallingFast(let limit):
            guard let rate else { return false }
            return rate <= -limit
        case .risingFast(let limit):
            guard let rate else { return false }
            return rate >= limit
        }
    }

    /// Hysteresis: the alert re-arms only once the condition has clearly cleared.
    func hasCleared(value: Double, rate: Double?, projected: Double?) -> Bool {
        switch kind {
        case .predictiveLow(let threshold, _):
            guard let projected else { return true }
            return projected >= threshold + 10
        case .fallingFast(let limit):
            guard let rate else { return true }
            return rate > -limit / 2
        case .risingFast(let limit):
            guard let rate else { return true }
            return rate < limit / 2
        }
    }

    var minutesAhead: Double {
        if case .predictiveLow(_, let minutes) = kind { return Double(minutes) }
        return 20
    }
}
