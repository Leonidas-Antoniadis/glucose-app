import Foundation

/// Something the app should deliver as a notification.
public struct AlertEvent: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case initial
        case reminder(count: Int)
        case afterSnooze
    }

    public let ruleID: UUID
    public let ruleName: String
    public let direction: AlertDirection
    public let valueMgdL: Double
    public let date: Date
    public let sound: SoundStyle
    public let isCritical: Bool
    public let criticalVolume: Double
    public let kind: Kind

    public init(ruleID: UUID, ruleName: String, direction: AlertDirection, valueMgdL: Double, date: Date,
                sound: SoundStyle, isCritical: Bool, criticalVolume: Double, kind: Kind) {
        self.ruleID = ruleID
        self.ruleName = ruleName
        self.direction = direction
        self.valueMgdL = valueMgdL
        self.date = date
        self.sound = sound
        self.isCritical = isCritical
        self.criticalVolume = criticalVolume
        self.kind = kind
    }
}

/// Evaluates every new reading against the rule set.
///
/// - Only the most severe active rule in each direction may sound; less severe rules that are
///   crossed at the same time are marked as handled, so you get one alarm, not three.
/// - A rule fires once per crossing, repeats per its settings until acknowledged, and re-arms
///   only after the value recovers past threshold + margin.
/// - Repeats are checked when readings arrive (about every minute). Missing-data alerts are
///   scheduled separately because they must fire even if the app is dead.
public struct AlertEngine: Sendable {
    public struct RuleState: Hashable, Sendable {
        public var crossedSince: Date?
        public var firedAt: Date?
        public var lastNotifiedAt: Date?
        public var repeatCount = 0
        public var snoozedUntil: Date?
    }

    public struct TrendState: Hashable, Sendable {
        public var fired = false
        public var snoozedUntil: Date?
    }

    public var ruleSet: AlertRuleSet
    public var calendar: Calendar
    public private(set) var states: [UUID: RuleState] = [:]
    public private(set) var trendStates: [UUID: TrendState] = [:]
    /// The last 30 minutes of readings, for trend calculations.
    public private(set) var recent: [GlucoseReading] = []
    /// Log of every decision, for debugging and tuning thresholds.
    public private(set) var log: [String] = []
    public var maxLogEntries = 500

    public init(ruleSet: AlertRuleSet, calendar: Calendar = .current) {
        self.ruleSet = ruleSet
        self.calendar = calendar
    }

    public mutating func process(_ reading: GlucoseReading) -> [AlertEvent] {
        let now = reading.timestamp
        let value = reading.mgdL
        var events: [AlertEvent] = []

        recent.append(reading)
        recent.removeAll { now.timeIntervalSince($0.timestamp) > 30 * 60 || $0.timestamp > now }

        // Forget state for rules that were deleted.
        let ids = Set(ruleSet.rules.map(\.id))
        states = states.filter { ids.contains($0.key) }

        for direction in AlertDirection.allCases {
            let rules = ruleSet.rules(for: direction)
                .filter(\.isEnabled)
                .sorted { $0.isMoreSevere(than: $1) }

            // 1. Track crossing / recovery for every rule.
            for rule in rules {
                var state = states[rule.id] ?? RuleState()
                if rule.isCrossed(by: value) {
                    if state.crossedSince == nil { state.crossedSince = now }
                } else {
                    state.crossedSince = nil
                    if rule.hasRecovered(at: value), state.firedAt != nil {
                        state = RuleState()
                        record(now, "re-armed \(rule.name) at \(value)")
                    }
                }
                states[rule.id] = state
            }

            // 2. Rules that are crossed, confirmed and inside their schedule.
            let active = rules.filter { rule in
                guard let since = states[rule.id]?.crossedSince else { return false }
                let confirmed = now.timeIntervalSince(since) >= Double(rule.confirmationMinutes) * 60
                return confirmed && rule.schedule.isActive(at: now, calendar: calendar)
            }
            guard let top = active.first else { continue }

            // 3. Less severe rules are covered by the top one.
            for rule in active.dropFirst() where states[rule.id]?.firedAt == nil {
                states[rule.id]?.firedAt = now
                record(now, "suppressed \(rule.name) (covered by \(top.name)) at \(value)")
            }

            // 4. Decide whether the top rule sounds now.
            if let kind = dueKind(for: top, now: now) {
                var state = states[top.id] ?? RuleState()
                switch kind {
                case .initial:
                    state.firedAt = now
                    state.repeatCount = 0
                case .afterSnooze:
                    state.snoozedUntil = nil
                    state.repeatCount = 0
                case .reminder(let count):
                    state.repeatCount = count
                }
                state.lastNotifiedAt = now
                states[top.id] = state
                events.append(AlertEvent(
                    ruleID: top.id, ruleName: top.name, direction: direction, valueMgdL: value, date: now,
                    sound: top.sound, isCritical: top.isCritical, criticalVolume: top.criticalVolume, kind: kind
                ))
                record(now, "fired \(top.name) (\(kind)) at \(value)")
            }
        }
        events += processTrendAlerts(value: value, now: now)
        return events
    }

    /// Predictive and rate-of-change alerts: one alert per episode, re-armed with hysteresis.
    private mutating func processTrendAlerts(value: Double, now: Date) -> [AlertEvent] {
        let ids = Set(ruleSet.trendAlerts.map(\.id))
        trendStates = trendStates.filter { ids.contains($0.key) }

        let rate = Trend.ratePerMinute(recent)
        // A threshold low that is already sounding makes "low soon" redundant.
        let lowAlreadyCrossed = ruleSet.rules(for: .low).contains { $0.isEnabled && $0.isCrossed(by: value) }
        var events: [AlertEvent] = []

        for alert in ruleSet.trendAlerts where alert.isEnabled {
            let projected = Trend.projected(recent, minutesAhead: alert.minutesAhead)
            var state = trendStates[alert.id] ?? TrendState()

            if state.fired, alert.hasCleared(value: value, rate: rate, projected: projected) {
                state = TrendState()
                record(now, "re-armed \(alert.name)")
            }
            let triggered = alert.isTriggered(value: value, rate: rate, projected: projected)
            let suppressed = alert.kind.direction == .low && lowAlreadyCrossed
            let snoozed = state.snoozedUntil.map { now < $0 } ?? false

            if triggered, !state.fired, !suppressed, !snoozed, alert.schedule.isActive(at: now, calendar: calendar) {
                state.fired = true
                events.append(AlertEvent(
                    ruleID: alert.id, ruleName: alert.name, direction: alert.kind.direction, valueMgdL: value, date: now,
                    sound: alert.sound, isCritical: alert.isCritical, criticalVolume: 1, kind: .initial
                ))
                record(now, "fired \(alert.name) at \(value), rate \(rate.map { String(format: "%.2f", $0) } ?? "-")")
            }
            trendStates[alert.id] = state
        }
        return events
    }

    /// Acknowledging silences the rule for its snooze duration.
    public mutating func acknowledge(ruleID: UUID, at date: Date) {
        if let rule = ruleSet.rules.first(where: { $0.id == ruleID }) {
            snooze(ruleID: ruleID, until: date.addingTimeInterval(Double(rule.snoozeMinutes) * 60))
        } else if let alert = ruleSet.trendAlerts.first(where: { $0.id == ruleID }) {
            trendStates[ruleID, default: TrendState()].snoozedUntil = date.addingTimeInterval(Double(alert.snoozeMinutes) * 60)
            record(date, "snoozed \(alert.name)")
        }
    }

    public mutating func snooze(ruleID: UUID, until date: Date) {
        guard states[ruleID] != nil else { return }
        states[ruleID]?.snoozedUntil = date
        record(date, "snoozed \(ruleID) until \(date)")
    }

    /// Moves every stored time by `interval`, for when readings were re-dated after the phone clock
    /// changed. Keeps confirmation delays, repeat intervals and snoozes running as before instead
    /// of waiting for the clock to catch up.
    public mutating func shiftTimeline(by interval: TimeInterval) {
        guard interval != 0 else { return }
        func shift(_ date: Date?) -> Date? { date?.addingTimeInterval(interval) }
        states = states.mapValues { state in
            var state = state
            state.crossedSince = shift(state.crossedSince)
            state.firedAt = shift(state.firedAt)
            state.lastNotifiedAt = shift(state.lastNotifiedAt)
            state.snoozedUntil = shift(state.snoozedUntil)
            return state
        }
        trendStates = trendStates.mapValues { state in
            var state = state
            state.snoozedUntil = shift(state.snoozedUntil)
            return state
        }
        recent = recent.map { $0.retimed(to: $0.timestamp.addingTimeInterval(interval)) }
        if let last = recent.last { record(last.timestamp, String(format: "timeline shifted by %.0f s", interval)) }
    }

    /// Ids of rules that are currently past their threshold (for the home screen status).
    public var activeRuleIDs: [UUID] {
        states.filter { $0.value.crossedSince != nil }.map(\.key)
    }

    private func dueKind(for rule: AlertRule, now: Date) -> AlertEvent.Kind? {
        let state = states[rule.id] ?? RuleState()
        guard state.firedAt != nil else { return .initial }
        if let until = state.snoozedUntil {
            return now >= until ? .afterSnooze : nil
        }
        // A rule marked as covered (never notified) stays quiet until it re-arms.
        guard let last = state.lastNotifiedAt, let interval = rule.repeatIntervalMinutes else { return nil }
        if let max = rule.maxRepeats, state.repeatCount >= max { return nil }
        guard now.timeIntervalSince(last) >= Double(interval) * 60 else { return nil }
        return .reminder(count: state.repeatCount + 1)
    }

    private mutating func record(_ date: Date, _ message: String) {
        log.append("\(ISO8601DateFormatter().string(from: date)) \(message)")
        if log.count > maxLogEntries {
            log.removeFirst(log.count - maxLogEntries)
        }
    }
}
