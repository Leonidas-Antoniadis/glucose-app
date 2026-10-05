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

    /// - Parameters:
    ///   - period: only readings inside this interval are used.
    ///   - expectedIntervalMinutes: sensor reading interval (1 minute for Libre 2 Plus).
    public init?(readings: [GlucoseReading], period: DateInterval, expectedIntervalMinutes: Double = 1) {
        let values = readings
            .filter { period.contains($0.timestamp) }
            .map(\.mgdL)
        self.init(values: values, expectedCount: period.duration / 60 / expectedIntervalMinutes)
    }

    /// - Parameter expectedCount: how many readings a complete period would contain.
    public init?(values: [Double], expectedCount: Double) {
        guard !values.isEmpty else { return nil }

        let n = Double(values.count)
        let mean = values.reduce(0, +) / n
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / n
        let sd = variance.squareRoot()

        count = values.count
        meanMgdL = mean
        standardDeviationMgdL = sd
        coefficientOfVariation = mean > 0 ? sd / mean * 100 : 0
        gmiPercent = 3.31 + 0.02392 * mean

        func fraction(_ predicate: (Double) -> Bool) -> Double {
            Double(values.filter(predicate).count) / n
        }
        ranges = RangeBreakdown(
            veryLow: fraction { $0 < 54 },
            low: fraction { $0 >= 54 && $0 < 70 },
            inRange: fraction { $0 >= 70 && $0 <= 180 },
            high: fraction { $0 > 180 && $0 <= 250 },
            veryHigh: fraction { $0 > 250 }
        )

        dataSufficiency = expectedCount > 0 ? min(1, n / expectedCount) : 0
    }
}
