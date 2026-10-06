import Foundation

/// Fractions of readings in the international-consensus ranges (Battelino et al., 2019).
public struct RangeBreakdown: Hashable, Sendable {
    public var veryLow: Double   // < 54 mg/dL
    public var low: Double       // 54-69
    public var inRange: Double   // 70-180
    public var high: Double      // 181-250
    public var veryHigh: Double  // > 250

    /// Time below range (< 70), including very low.
    public var belowRange: Double { veryLow + low }
    /// Time above range (> 180), including very high.
    public var aboveRange: Double { high + veryHigh }

    /// Consensus targets for most adults with type 1 or type 2 diabetes.
    public var meetsConsensusTargets: Bool {
        inRange > 0.70 && belowRange < 0.04 && veryLow < 0.01 && aboveRange < 0.25 && veryHigh < 0.05
    }
}

public struct GlucoseStatistics: Hashable, Sendable {
    public let count: Int
    public let meanMgdL: Double
    /// Population standard deviation.
    public let standardDeviationMgdL: Double
    /// Coefficient of variation in percent. Target: 36% or lower.
    public let coefficientOfVariation: Double
    /// Glucose Management Indicator in percent: 3.31 + 0.02392 x mean mg/dL.
    public let gmiPercent: Double
    public let ranges: RangeBreakdown
    /// Fraction of expected readings present in the period (reports need > 70% over 14 days).
    public let dataSufficiency: Double

    public static let cvTarget = 36.0
    public static let sufficiencyTarget = 0.70

    public var isCVStable: Bool { coefficientOfVariation <= Self.cvTarget }
    public var hasSufficientData: Bool { dataSufficiency >= Self.sufficiencyTarget }

    /// Each reading counts by the time it covers (see `ReadingPipeline.timeWeights`), so the
    /// 15-minute history imported by NFC weighs as much as the 15 live minutes it stands for.
    /// - Parameter period: only readings inside this interval are used.
    public init?(readings: [GlucoseReading], period: DateInterval) {
        let inPeriod = readings.filter { period.contains($0.timestamp) }.sorted { $0.timestamp < $1.timestamp }
        self.init(values: inPeriod.map(\.mgdL), minutes: ReadingPipeline.timeWeights(inPeriod),
                  expectedMinutes: period.duration / 60)
    }

    /// Unweighted: every value counts as one minute.
    /// - Parameter expectedCount: how many readings a complete period would contain.
    public init?(values: [Double], expectedCount: Double) {
        self.init(values: values, minutes: values.map { _ in 1 }, expectedMinutes: expectedCount)
    }

    /// - Parameters:
    ///   - minutes: the time each value stands for.
    ///   - expectedMinutes: the length of the period; covered minutes over this is the data sufficiency.
    public init?(values: [Double], minutes: [Double], expectedMinutes: Double) {
        guard !values.isEmpty, values.count == minutes.count else { return nil }
        let total = minutes.reduce(0, +)
        guard total > 0 else { return nil }

        let mean = zip(values, minutes).reduce(0) { $0 + $1.0 * $1.1 } / total
        let variance = zip(values, minutes).reduce(0) { $0 + ($1.0 - mean) * ($1.0 - mean) * $1.1 } / total
        let sd = variance.squareRoot()

        count = values.count
        meanMgdL = mean
        standardDeviationMgdL = sd
        coefficientOfVariation = mean > 0 ? sd / mean * 100 : 0
        gmiPercent = 3.31 + 0.02392 * mean

        func fraction(_ predicate: (Double) -> Bool) -> Double {
            zip(values, minutes).reduce(0) { predicate($1.0) ? $0 + $1.1 : $0 } / total
        }
        ranges = RangeBreakdown(
            veryLow: fraction { $0 < 54 },
            low: fraction { $0 >= 54 && $0 < 70 },
            inRange: fraction { $0 >= 70 && $0 <= 180 },
            high: fraction { $0 > 180 && $0 <= 250 },
            veryHigh: fraction { $0 > 250 }
        )

        dataSufficiency = expectedMinutes > 0 ? min(1, total / expectedMinutes) : 0
    }
}
