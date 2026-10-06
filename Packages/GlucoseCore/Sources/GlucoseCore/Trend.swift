import Foundation

public enum TrendArrow: String, Codable, Sendable {
    case fallingQuickly, falling, stable, rising, risingQuickly, unknown

    public var symbol: String {
        switch self {
        case .fallingQuickly: return "↓"
        case .falling: return "↘"
        case .stable: return "→"
        case .rising: return "↗"
        case .risingQuickly: return "↑"
        case .unknown: return "?"
        }
    }

    /// What VoiceOver reads for the arrow.
    public var spokenName: String {
        switch self {
        case .fallingQuickly: return "Falling quickly"
        case .falling: return "Falling"
        case .stable: return "Steady"
        case .rising: return "Rising"
        case .risingQuickly: return "Rising quickly"
        case .unknown: return "Trend unknown"
        }
    }
}

public enum Trend {
    /// Rate of change in mg/dL per minute, from a least-squares fit over the last `windowMinutes`.
    /// Only the latest reading's sensor counts: two sensors read differently, and fitting across
    /// a sensor change would turn their offset into a slope.
    /// Returns nil when there are fewer than `minimumPoints` readings in the window.
    public static func ratePerMinute(_ readings: [GlucoseReading], windowMinutes: Double = 15, minimumPoints: Int = 3) -> Double? {
        guard let latest = readings.max(by: { $0.timestamp < $1.timestamp }) else { return nil }
        let windowStart = latest.timestamp.addingTimeInterval(-windowMinutes * 60)
        let points = readings
            .filter { $0.sensorSerial == latest.sensorSerial }
            .filter { $0.timestamp >= windowStart && $0.timestamp <= latest.timestamp }
            .map { (x: $0.timestamp.timeIntervalSince(windowStart) / 60, y: $0.mgdL) }
        guard points.count >= minimumPoints else { return nil }

        let n = Double(points.count)
        let meanX = points.reduce(0) { $0 + $1.x } / n
        let meanY = points.reduce(0) { $0 + $1.y } / n
        var numerator = 0.0
        var denominator = 0.0
        for point in points {
            numerator += (point.x - meanX) * (point.y - meanY)
            denominator += (point.x - meanX) * (point.x - meanX)
        }
        guard denominator > 0 else { return nil }
        return numerator / denominator
    }

    public static func arrow(forRate rate: Double?) -> TrendArrow {
        guard let rate else { return .unknown }
        switch rate {
        case ..<(-2): return .fallingQuickly
        case ..<(-1): return .falling
        case ...1: return .stable
        case ...2: return .rising
        default: return .risingQuickly
        }
    }

    /// Linear projection `minutesAhead` into the future, used for predictive alerts.
    public static func projected(_ readings: [GlucoseReading], minutesAhead: Double) -> Double? {
        guard let rate = ratePerMinute(readings),
              let latest = readings.max(by: { $0.timestamp < $1.timestamp }) else { return nil }
        return latest.mgdL + rate * minutesAhead
    }
}
