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
///   crossed at the same time are marked as handled, so you get one alarm, not three. Once the
///   more severe rule stops, a covered rule reminds on its own repeat interval.
/// - A rule fires once per crossing, repeats per its settings until acknowledged, and re-arms
///   only after the value recovers past threshold + margin.
/// - A reading that comes long after the previous one starts a new episode, since a recovery
///   or a new low inside the gap was never seen.
/// - Repeats are checked when readings arrive (about every minute). Missing-data alerts are
///   scheduled separately because they must fire even if the app is dead.
public struct AlertEngine: Sendable {
    public struct RuleState: Codable, Hashable, Sendable {
        /// When the value first went past the threshold. Readings between the threshold and the
        /// re-arm margin keep it, so a confirmation delay isn't restarted by noise.
        public var crossedSince: Date?
        /// The latest value was past the threshold.
        public var isCrossed = false
        public var firedAt: Date?
        public var lastNotifiedAt: Date?
        public var repeatCount = 0
        public var snoozedUntil: Date?

        public init() {}
    }

    public struct TrendState: Codable, Hashable, Sendable {
        public var fired = false
        public var snoozedUntil: Date?

        public init() {}
    }

    /// The engine's memory, saved between launches so snoozes, repeats and the decision log
    /// survive iOS relaunching the app.
    public struct Snapshot: Codable, Sendable {
        public var states: [UUID: RuleState]
        public var trendStates: [UUID: TrendState]
        public var recent: [GlucoseReading]
        public var log: [String]
        public var lastProcessedAt: Date?
    }

    /// A reading more than this long after the previous one starts a new episode.
    public static let gapResetMinutes: Double = 15
    /// Trend alerts need readings spanning at least this long: a slope over three values a
    /// minute apart is mostly noise.
    public static let minimumTrendSpanMinutes: Double = 10

    public var ruleSet: AlertRuleSet
    /// Follows the phone's current time zone, so schedules use local time after travelling.
    public var calendar: Calendar
    public private(set) var states: [UUID: RuleState] = [:]
    public private(set) var trendStates: [UUID: TrendState] = [:]
    /// The last 30 minutes of readings, for trend calculations.
    public private(set) var recent: [GlucoseReading] = []
    /// Log of every decision, for debugging and tuning thresholds. Times are local, values are in `unit`.
    public private(set) var log: [String] = []
    public private(set) var lastProcessedAt: Date?
    public var maxLogEntries = 500
    /// The unit values are written in in the decision log.
    public var unit: GlucoseUnit = .mgdL
    /// The last quiet reason logged per alert.
    private var quietNotes: [UUID: String] = [:]

    public init(ruleSet: AlertRuleSet, calendar: Calendar = .autoupdatingCurrent) {
        self.ruleSet = ruleSet
        self.calendar = calendar
    }

    // MARK: Saving and restoring

    public var snapshot: Snapshot {
        Snapshot(states: states, trendStates: trendStates, recent: recent, log: log, lastProcessedAt: lastProcessedAt)
    }

    /// Restores a saved snapshot. State for rules that no longer exist, and episodes older than
    /// `maxAge` with no snooze still running, are dropped.
    public mutating func restore(_ snapshot: Snapshot, now: Date, maxAge: TimeInterval = 6 * 3600) {
        let ruleIDs = Set(ruleSet.rules.map(\.id))
        let trendIDs = Set(ruleSet.trendAlerts.map(\.id))
        func isFresh(_ dates: [Date?], snooze: Date?) -> Bool {
            if let snooze, snooze > now { return true }
            return dates.compactMap { $0 }.contains { now.timeIntervalSince($0) < maxAge }
        }
        states = snapshot.states.filter { id, state in
            ruleIDs.contains(id) && isFresh([state.crossedSince, state.firedAt, state.lastNotifiedAt], snooze: state.snoozedUntil)
        }
        trendStates = snapshot.trendStates.filter { id, state in
            trendIDs.contains(id) && (state.fired || (state.snoozedUntil.map { $0 > now } ?? false))
        }
        recent = snapshot.recent.filter { now.timeIntervalSince($0.timestamp) <= 30 * 60 }
        log = Array(snapshot.log.suffix(maxLogEntries))
        lastProcessedAt = snapshot.lastProcessedAt
    }

    /// Adds readings for trend calculations without evaluating any rule, e.g. the backfilled
    /// minutes of a Bluetooth packet or the history loaded at launch.
    public mutating func addHistory(_ readings: [GlucoseReading]) {
        guard !readings.isEmpty else { return }
        mergeRecent(readings)
    }

    private mutating func mergeRecent(_ incoming: [GlucoseReading]) {
        var byID: [String: GlucoseReading] = [:]
        for reading in recent + incoming { byID[reading.id] = reading }
        let merged = byID.values.sorted { $0.timestamp < $1.timestamp }
        guard let newest = merged.last else { recent = []; return }
        recent = merged.filter { newest.timestamp.timeIntervalSince($0.timestamp) <= 30 * 60 }
    }

    // MARK: Evaluating readings

    public mutating func process(_ reading: GlucoseReading) -> [AlertEvent] {
        let now = reading.timestamp
        let value = reading.mgdL
        var events: [AlertEvent] = []

        if let last = lastProcessedAt, now.timeIntervalSince(last) > Self.gapResetMinutes * 60 {
            startNewEpisode(at: now, gapMinutes: now.timeIntervalSince(last) / 60)
        }
        lastProcessedAt = now

        // A new sensor reads differently: don't fit a trend across the change.
        if let previous = recent.last, previous.sensorSerial != reading.sensorSerial { recent = [] }
        mergeRecent([reading])
        recent.removeAll { $0.timestamp > now }

        // Forget state for rules that were deleted or turned off, so a rule turned back on starts fresh.
        let enabledIDs = Set(ruleSet.rules.filter(\.isEnabled).map(\.id))
        states = states.filter { enabledIDs.contains($0.key) }

        var audibleLowActive = false
        for direction in AlertDirection.allCases {
            let rules = ruleSet.rules(for: direction)
                .filter(\.isEnabled)
                .sorted { $0.isMoreSevere(than: $1) }

            // 1. Track crossing / recovery for every rule.
            for rule in rules {
                var state = states[rule.id] ?? RuleState()
                state.isCrossed = rule.isCrossed(by: value)
                if state.isCrossed {
                    if state.crossedSince == nil { state.crossedSince = now }
                } else if rule.hasRecovered(at: value) {
                    if state.firedAt != nil { record(now, "re-armed \(rule.name) at \(show(value))") }
                    state = RuleState()
                    quietNotes[rule.id] = nil
                }
                states[rule.id] = state
            }

            // 2. Rules that are crossed now, confirmed and inside their schedule.
            let active = rules.filter { rule in
                guard let state = states[rule.id], state.isCrossed, let since = state.crossedSince else { return false }
                let confirmed = now.timeIntervalSince(since) >= Double(rule.confirmationMinutes) * 60
                let scheduled = rule.schedule.isActive(at: now, calendar: calendar)
                if state.firedAt == nil, !(confirmed && scheduled) {
                    // Logged once per reason, so the value is when it started.
                    let reason = !scheduled ? "outside its schedule" : "waiting \(rule.confirmationMinutes) min to confirm"
                    noteQuiet(rule.id, rule.name, reason, at: now, value: value)
                }
                return confirmed && scheduled
            }
            if direction == .low {
                audibleLowActive = active.contains { rule in
                    let snoozed = states[rule.id]?.snoozedUntil.map { now < $0 } ?? false
                    return (rule.sound != .silent || rule.isCritical) && !snoozed
                }
            }
            guard let top = active.first else { continue }

            // 3. Less severe rules are covered by the top one. They count as notified now, so
            // once the top rule stops they remind on their own interval unless acknowledged.
            let topSnooze = states[top.id]?.snoozedUntil
            for rule in active.dropFirst() where states[rule.id]?.firedAt == nil {
                states[rule.id]?.firedAt = now
                states[rule.id]?.lastNotifiedAt = now
                states[rule.id]?.snoozedUntil = topSnooze
                record(now, "suppressed \(rule.name) (covered by \(top.name)) at \(show(value))")
            }

            // 4. Decide whether the top rule sounds now.
            if let kind = dueKind(for: top, now: now) {
                var state = states[top.id] ?? RuleState()
                switch kind {
                case .initial:
                    state.firedAt = now
                    state.repeatCount = 0
                    state.snoozedUntil = nil
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
                record(now, "fired \(top.name) (\(kind)) at \(show(value))")
                quietNotes[top.id] = nil
            } else if let reason = quietReason(for: top, now: now) {
                noteQuiet(top.id, top.name, reason, at: now)
            }
        }
        events += processTrendAlerts(value: value, now: now, audibleLowActive: audibleLowActive)
        return events
    }

    /// Forgets crossings, repeat counts and fired trend alerts after a gap in the data. Snoozes
    /// that are still running are kept.
    private mutating func startNewEpisode(at now: Date, gapMinutes: Double) {
        states = states.mapValues { old in
            var state = RuleState()
            if let until = old.snoozedUntil, until > now { state.snoozedUntil = until }
            return state
        }
        trendStates = trendStates.mapValues { old in
            var state = TrendState()
            if let until = old.snoozedUntil, until > now { state.snoozedUntil = until }
            return state
        }
        recent.removeAll { now.timeIntervalSince($0.timestamp) > 30 * 60 }
        quietNotes = [:]
        record(now, String(format: "new episode after a %.0f-minute gap", gapMinutes))
    }

    /// Predictive and rate-of-change alerts: one alert per episode, re-armed with hysteresis.
    private mutating func processTrendAlerts(value: Double, now: Date, audibleLowActive: Bool) -> [AlertEvent] {
        let enabledIDs = Set(ruleSet.trendAlerts.filter(\.isEnabled).map(\.id))
        trendStates = trendStates.filter { enabledIDs.contains($0.key) }

        let windowStart = now.addingTimeInterval(-15 * 60)
        let window = recent.filter { $0.timestamp >= windowStart }
        let span = (window.last?.timestamp.timeIntervalSince(window.first?.timestamp ?? now) ?? 0) / 60
        let hasTrend = span >= Self.minimumTrendSpanMinutes
        let rate = hasTrend ? Trend.ratePerMinute(recent) : nil
        var events: [AlertEvent] = []

        for alert in ruleSet.trendAlerts where alert.isEnabled {
            let projected = hasTrend ? Trend.projected(recent, minutesAhead: alert.minutesAhead) : nil
            var state = trendStates[alert.id] ?? TrendState()

            if state.fired, alert.hasCleared(value: value, rate: rate, projected: projected) {
                state.fired = false
                record(now, "re-armed \(alert.name)")
            }
            let triggered = alert.isTriggered(value: value, rate: rate, projected: projected)
            // A low rule that is already sounding makes "low soon" and "falling fast" redundant.
            // A silent, snoozed or not-yet-confirmed one doesn't.
            let suppressed = alert.kind.direction == .low && audibleLowActive
            let snoozed = state.snoozedUntil.map { now < $0 } ?? false

            if triggered, !state.fired, !suppressed, !snoozed, alert.schedule.isActive(at: now, calendar: calendar) {
                state.fired = true
                events.append(AlertEvent(
                    ruleID: alert.id, ruleName: alert.name, direction: alert.kind.direction, valueMgdL: value, date: now,
                    sound: alert.sound, isCritical: alert.isCritical, criticalVolume: 1, kind: .initial
                ))
                record(now, "fired \(alert.name) at \(show(value)), rate \(rate.map { unit.formatRate(mgdLPerMinute: $0) } ?? "-")")
                quietNotes[alert.id] = nil
            } else if triggered, !state.fired {
                let reason = suppressed ? "a low alert is already sounding" : snoozed ? "snoozed" : "outside its schedule"
                noteQuiet(alert.id, alert.name, reason, at: now)
            }
            trendStates[alert.id] = state
        }
        return events
    }

    // MARK: Snooze

    /// Snoozes an alert that is sounding, together with the other sounding rules in the same
    /// direction. Snooze on an old alert (the rule has re-armed since) does nothing, so it can't
    /// silence the next episode. `eventDate` is when the alert was sent: if the engine has no
    /// state for the rule at all (the app was relaunched since), a recent alert is snoozed anyway.
    @discardableResult
    public mutating func acknowledge(ruleID: UUID, at date: Date, eventDate: Date? = nil) -> Bool {
        if let rule = ruleSet.rules.first(where: { $0.id == ruleID }) {
            if isFiring(ruleID) {
                for other in ruleSet.rules(for: rule.direction) where other.isEnabled && isFiring(other.id) {
                    states[other.id]?.snoozedUntil = date.addingTimeInterval(Double(other.snoozeMinutes) * 60)
                    record(date, "snoozed \(other.name)")
                }
                return true
            }
            if states[ruleID] == nil, let eventDate, date.timeIntervalSince(eventDate) < Double(rule.snoozeMinutes) * 60 {
                states[ruleID, default: RuleState()].snoozedUntil = date.addingTimeInterval(Double(rule.snoozeMinutes) * 60)
                record(date, "snoozed \(rule.name) (alert from before a relaunch)")
                return true
            }
            record(date, "ignored snooze for \(rule.name): not sounding")
            return false
        }
        if let alert = ruleSet.trendAlerts.first(where: { $0.id == ruleID }) {
            let recentEvent = eventDate.map { date.timeIntervalSince($0) < Double(alert.snoozeMinutes) * 60 } ?? false
            guard isFiring(ruleID) || (trendStates[ruleID] == nil && recentEvent) else {
                record(date, "ignored snooze for \(alert.name): not sounding")
                return false
            }
            trendStates[ruleID, default: TrendState()].snoozedUntil = date.addingTimeInterval(Double(alert.snoozeMinutes) * 60)
            record(date, "snoozed \(alert.name)")
            return true
        }
        return false
    }

    public mutating func snooze(ruleID: UUID, until date: Date) {
        states[ruleID, default: RuleState()].snoozedUntil = date
        record(date, "snoozed \(ruleID) until \(date)")
    }

    /// Whether an alert is in an episode it already announced: a threshold rule that fired and
    /// hasn't re-armed, or a trend alert that fired.
    public func isFiring(_ ruleID: UUID) -> Bool {
        if let state = states[ruleID] { return state.firedAt != nil && state.crossedSince != nil }
        return trendStates[ruleID]?.fired ?? false
    }

    // MARK: Calibration changes

    /// Recomputes the trend window with a new calibration and re-arms the trend alerts, so the
    /// step between old and new values isn't read as a fast rise or fall. Snoozes are kept.
    public mutating func recalibrate(sensorSerial: String, calibration: Calibration) {
        recent = recent.map { reading in
            guard reading.sensorSerial == sensorSerial else { return reading }
            return reading.recalibrated(with: calibration) ?? reading
        }
        trendStates = trendStates.mapValues { state in
            var state = state
            state.fired = false
            return state
        }
        if let last = recent.last { record(last.timestamp, "recalibrated the trend window") }
    }

    // MARK: Clock changes

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
        lastProcessedAt = shift(lastProcessedAt)
        if let last = recent.last { record(last.timestamp, String(format: "timeline shifted by %.0f s", interval)) }
    }

    /// Ids of rules whose latest value is past their threshold (for the home screen status).
    public var activeRuleIDs: [UUID] {
        states.filter { $0.value.isCrossed }.map(\.key)
    }

    private func dueKind(for rule: AlertRule, now: Date) -> AlertEvent.Kind? {
        let state = states[rule.id] ?? RuleState()
        if let until = state.snoozedUntil, now < until { return nil }
        guard state.firedAt != nil else { return .initial }
        if state.snoozedUntil != nil { return .afterSnooze }
        guard let last = state.lastNotifiedAt, let interval = rule.repeatIntervalMinutes else { return nil }
        if let max = rule.maxRepeats, state.repeatCount >= max { return nil }
        guard now.timeIntervalSince(last) >= Double(interval) * 60 else { return nil }
        return .reminder(count: state.repeatCount + 1)
    }

    /// Why the top rule stays quiet, for the decision log. Nil for the normal wait between repeats.
    private func quietReason(for rule: AlertRule, now: Date) -> String? {
        let state = states[rule.id] ?? RuleState()
        if let until = state.snoozedUntil, now < until { return "snoozed" }
        guard rule.repeatIntervalMinutes != nil else { return "no repeats" }
        if let max = rule.maxRepeats, state.repeatCount >= max { return "repeats used up" }
        return nil
    }

    /// Logs why an alert stays quiet, once per reason, so a long episode doesn't flood the log.
    private mutating func noteQuiet(_ id: UUID, _ name: String, _ reason: String, at date: Date, value: Double? = nil) {
        guard quietNotes[id] != reason else { return }
        quietNotes[id] = reason
        record(date, "\(name) stays quiet: \(reason)" + (value.map { " at \(show($0))" } ?? ""))
    }

    // MARK: Decision log

    /// Adds a line from outside the engine, e.g. a late reading the app didn't alert on.
    public mutating func note(_ message: String, at date: Date) {
        record(date, message)
    }

    /// Replaces the log, e.g. to carry it into a new engine after the data source changes.
    public mutating func restoreLog(_ lines: [String]) {
        log = Array(lines.suffix(maxLogEntries))
    }

    private func show(_ mgdL: Double) -> String {
        unit.formatReading(mgdL: mgdL, includeSymbol: true)
    }

    /// Local time, as on the phone's clock and in the notifications.
    private func timeText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    private mutating func record(_ date: Date, _ message: String) {
        log.append("\(timeText(date)) \(message)")
        if log.count > maxLogEntries {
            log.removeFirst(log.count - maxLogEntries)
        }
    }
}
