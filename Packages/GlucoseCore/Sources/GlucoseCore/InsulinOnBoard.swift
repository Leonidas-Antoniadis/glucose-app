import Foundation

/// How a dose of insulin acts over time: the exponential curve OpenAPS and Loop use
/// (Maksimovic, LoopKit/Loop#388), set by when the dose acts most and when it's done.
public struct InsulinCurve: Hashable, Sendable {
    /// Minutes until a dose has fully acted.
    public let actionMinutes: Double
    /// Minutes until a dose acts most.
    public let peakMinutes: Double

    /// Rapid-acting insulin (NovoRapid, Humalog, Apidra): acts most after 75 minutes, done after 5 hours.
    public static let rapid = InsulinCurve(actionMinutes: 300, peakMinutes: 75)

    public init(actionMinutes: Double, peakMinutes: Double) {
        self.actionMinutes = actionMinutes
        // The curve only exists with the peak before half the action time.
        self.peakMinutes = min(peakMinutes, actionMinutes * 0.45)
    }

    private var tau: Double { peakMinutes * (1 - peakMinutes / actionMinutes) / (1 - 2 * peakMinutes / actionMinutes) }
    private var rise: Double { 2 * tau / actionMinutes }
    private var scale: Double { 1 / (1 - rise + (1 + rise) * exp(-actionMinutes / tau)) }

    /// The share of a dose still to act `minutes` after it was taken: 1 when taken, 0 once it has
    /// fully acted, and 0 for a dose not taken yet (negative minutes).
    public func remaining(afterMinutes t: Double) -> Double {
        guard t >= 0, t < actionMinutes else { return 0 }
        let value = 1 - scale * (1 - rise) * ((t * t / (tau * actionMinutes * (1 - rise)) - t / tau - 1) * exp(-t / tau) + 1)
        return min(max(value, 0), 1)
    }
}

/// Fast-acting insulin still working, from the doses in the logbook.
public enum InsulinOnBoard {
    /// From this many units still working, glucose is likely to move.
    public static let activeUnits = 0.5

    /// The fast-acting doses still working at `date`, oldest first. Insulin of unknown type counts
    /// as fast-acting. Slow-acting (basal) insulin works evenly through the day, so it doesn't make
    /// glucose move and isn't counted.
    public static func doses(at date: Date, in entries: [LogEntry], curve: InsulinCurve = .rapid) -> [LogEntry] {
        entries.filter { entry in
            guard case .insulin(let units, let type) = entry.kind, type != .long, units > 0 else { return false }
            let minutes = date.timeIntervalSince(entry.date) / 60
            return minutes >= 0 && minutes < curve.actionMinutes
        }
        .sorted { $0.date < $1.date }
    }

    /// Units of fast-acting insulin still to act at `date`.
    public static func units(at date: Date, in entries: [LogEntry], curve: InsulinCurve = .rapid) -> Double {
        doses(at: date, in: entries, curve: curve).reduce(0) { total, entry in
            guard case .insulin(let units, _) = entry.kind else { return total }
            return total + units * curve.remaining(afterMinutes: date.timeIntervalSince(entry.date) / 60)
        }
    }

    /// When the insulin working at `date` falls below `threshold` units if no more is taken, to
    /// the minute. Nil when it already is.
    public static func time(whenBelow threshold: Double, after date: Date, in entries: [LogEntry],
                            curve: InsulinCurve = .rapid) -> Date? {
        let working = doses(at: date, in: entries, curve: curve)
        guard units(at: date, in: working, curve: curve) >= threshold else { return nil }
        for minute in 1...max(1, Int(curve.actionMinutes)) {
            let time = date.addingTimeInterval(Double(minute) * 60)
            if units(at: time, in: working, curve: curve) < threshold { return time }
        }
        return date.addingTimeInterval(curve.actionMinutes * 60)
    }
}

/// What the logbook says was going on at a moment: fast insulin still working, food and exercise.
/// The calibration advice and the accuracy checks both look at it.
public struct LogContext: Hashable, Sendable {
    /// Fast-acting insulin in the 2 hours before makes glucose move (the calibration guide's rule).
    public static let insulinMinutes: Double = 120
    /// Food in the 2 hours before makes glucose move.
    public static let foodMinutes: Double = 120
    /// Food is looked for this far back: 2 to 3 hours after eating, glucose may still be coming down.
    public static let foodLookbackMinutes: Double = 180
    /// Glucose can keep falling this long after exercise.
    public static let afterExerciseMinutes: Double = 60
    /// Nothing older matters: insulin acts for 5 hours, and exercise lasts up to 5 hours plus 1 after.
    public static let lookback: TimeInterval = 6 * 3600

    public let date: Date
    /// Fast-acting insulin still to act, in units.
    public let insulinOnBoard: Double
    /// The fast-acting doses still working, oldest first.
    public let workingDoses: [LogEntry]
    /// Food in the 3 hours before, newest first.
    public let foods: [LogEntry]
    /// Minutes since exercise ended, when it was in the hour before; 0 while it lasts.
    public let minutesSinceExercise: Double?

    /// Minutes since the newest food in the 3 hours before.
    public var minutesSinceFood: Double? {
        foods.first.map { date.timeIntervalSince($0.date) / 60 }
    }

    /// Minutes since the newest fast-acting dose still working.
    public var minutesSinceInsulin: Double? {
        workingDoses.last.map { date.timeIntervalSince($0.date) / 60 }
    }

    public static func at(_ date: Date, in entries: [LogEntry], curve: InsulinCurve = .rapid) -> LogContext {
        let working = InsulinOnBoard.doses(at: date, in: entries, curve: curve)
        var foods: [LogEntry] = []
        var sinceExercise: Double?
        for entry in entries where entry.date <= date {
            switch entry.kind {
            case .meal:
                if date.timeIntervalSince(entry.date) <= foodLookbackMinutes * 60 { foods.append(entry) }
            case .exercise(let minutes):
                let end = entry.date.addingTimeInterval(Double(minutes) * 60)
                let since = max(0, date.timeIntervalSince(end) / 60)
                if since <= afterExerciseMinutes { sinceExercise = min(sinceExercise ?? .infinity, since) }
            case .insulin, .note:
                break
            }
        }
        return LogContext(date: date, insulinOnBoard: InsulinOnBoard.units(at: date, in: working, curve: curve),
                          workingDoses: working, foods: foods.sorted { $0.date > $1.date },
                          minutesSinceExercise: sinceExercise)
    }
}
