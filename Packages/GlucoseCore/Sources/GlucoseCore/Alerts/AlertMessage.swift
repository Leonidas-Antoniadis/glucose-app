import Foundation

/// The words of an alert notification: the value and its direction in the title, then how fast
/// it moved and since when it has been past the threshold, so a slow slide reads differently
/// from a sudden drop without unlocking the phone.
public enum AlertMessage {
    /// "Lower · 64 mg/dL ↘". The arrow is left out when the trend is unknown.
    public static func title(for event: AlertEvent, unit: GlucoseUnit, arrow: TrendArrow) -> String {
        let value = unit.formatReading(mgdL: event.valueMgdL, includeSymbol: true)
        return arrow == .unknown ? "\(event.ruleName) · \(value)" : "\(event.ruleName) · \(value) \(arrow.symbol)"
    }

    /// "−9 in 15 min. Below 70 since 3:01 AM." `thresholdMgdL` and `since` come from the rule
    /// and the alert engine; trend alerts have neither. `time` formats a clock time.
    public static func body(for event: AlertEvent, unit: GlucoseUnit, change15: Double?, thresholdMgdL: Double?,
                            since: Date?, time: (Date) -> String) -> String {
        var parts: [String] = []
        switch event.kind {
        case .initial: break
        case .reminder(let count): parts.append("Reminder \(count)")
        case .afterSnooze: parts.append("Snooze over")
        }
        if let change15 { parts.append("\(signedChange(change15, unit: unit)) in 15 min") }
        if let thresholdMgdL, let since {
            parts.append("\(event.direction == .low ? "Below" : "Above") \(unit.format(mgdL: thresholdMgdL)) since \(time(since))")
        }
        guard !parts.isEmpty else { return "Glucose \(unit.formatReading(mgdL: event.valueMgdL, includeSymbol: true))" }
        return parts.joined(separator: ". ") + "."
    }

    /// The change from the reading about `minutes` ago (within 3 minutes of it, same sensor)
    /// to the newest one, in mg/dL. Nil without such a reading.
    public static func change(in readings: [GlucoseReading], minutes: Double = 15) -> Double? {
        guard let latest = readings.max(by: { $0.timestamp < $1.timestamp }) else { return nil }
        let target = latest.timestamp.addingTimeInterval(-minutes * 60)
        let earlier = readings
            .filter { $0.sensorSerial == latest.sensorSerial && abs($0.timestamp.timeIntervalSince(target)) <= 180 }
            .min { abs($0.timestamp.timeIntervalSince(target)) < abs($1.timestamp.timeIntervalSince(target)) }
        return earlier.map { latest.mgdL - $0.mgdL }
    }

    /// "−9", "+0.5", "±0": a change in the display unit with its sign.
    public static func signedChange(_ mgdL: Double, unit: GlucoseUnit) -> String {
        let size = unit.format(mgdL: abs(mgdL))
        if Double(size) == 0 { return "±0" }
        return (mgdL < 0 ? "−" : "+") + size
    }
}
