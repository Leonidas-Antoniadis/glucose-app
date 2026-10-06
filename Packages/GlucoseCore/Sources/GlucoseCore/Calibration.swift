import Foundation

/// A fingerstick value paired with the sensor's raw signal at the same moment.
public struct CalibrationPoint: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var date: Date
    public var referenceMgdL: Double
    public var raw: Double

    public init(id: UUID = UUID(), date: Date, referenceMgdL: Double, raw: Double) {
        self.id = id
        self.date = date
        self.referenceMgdL = referenceMgdL
        self.raw = raw
    }
}

/// Converts the sensor's raw signal to mg/dL: `mgdL = slope * raw + intercept`.
///
/// Abbott's factory algorithm is not public, so values are calibrated locally against
/// fingersticks, like xDrip's own calibration. Without calibrations the default
/// `raw / 8.5` is only a rough estimate.
public struct Calibration: Codable, Hashable, Sendable {
    public static let defaultSlope = 1 / 8.5
    /// Calibrations older than this are ignored.
    public static let maxAgeHours: Double = 96
    /// Weight halves every this many hours, so recent fingersticks count most.
    public static let halfLifeHours: Double = 24
    /// Slope may deviate from the default by at most this factor.
    public static let slopeRange: ClosedRange<Double> = (defaultSlope * 0.6)...(defaultSlope * 1.6)
    public static let interceptRange: ClosedRange<Double> = -80...80
    /// Two points need at least this spread in reference values for a slope fit.
    public static let minimumSpreadMgdL: Double = 40

    public var slope: Double
    public var intercept: Double
    public var pointCount: Int
    public var lastCalibration: Date?

    public init(slope: Double = Calibration.defaultSlope, intercept: Double = 0, pointCount: Int = 0, lastCalibration: Date? = nil) {
        self.slope = slope
        self.intercept = intercept
        self.pointCount = pointCount
        self.lastCalibration = lastCalibration
    }

    public static let uncalibrated = Calibration()

    public var isCalibrated: Bool { pointCount > 0 }

    public func mgdL(fromRaw raw: Double) -> Double {
        slope * raw + intercept
    }

    /// Whether a new fingerstick is recommended (none yet, or the last is over 24 h old).
    public func needsCalibration(now: Date) -> Bool {
        guard let last = lastCalibration else { return true }
        return now.timeIntervalSince(last) > 24 * 3600
    }

    /// Weighted least-squares fit over recent points, with sane limits on slope and intercept.
    public static func fit(_ points: [CalibrationPoint], now: Date) -> Calibration {
        let recent = points.filter {
            let ageHours = now.timeIntervalSince($0.date) / 3600
            return ageHours >= 0 && ageHours <= maxAgeHours && $0.raw > 0
        }
        guard !recent.isEmpty else { return .uncalibrated }
        let last = recent.map(\.date).max()

        let weights = recent.map { point -> Double in
            let ageHours = now.timeIntervalSince(point.date) / 3600
            return pow(0.5, ageHours / halfLifeHours)
        }
        let totalWeight = weights.reduce(0, +)
        let meanRaw = zip(recent, weights).reduce(0) { $0 + $1.0.raw * $1.1 } / totalWeight
        let meanRef = zip(recent, weights).reduce(0) { $0 + $1.0.referenceMgdL * $1.1 } / totalWeight

        let references = recent.map(\.referenceMgdL)
        let spread = (references.max() ?? 0) - (references.min() ?? 0)

        var slope = defaultSlope
        if recent.count >= 2, spread >= minimumSpreadMgdL {
            var covariance = 0.0
            var variance = 0.0
            for (point, weight) in zip(recent, weights) {
                covariance += weight * (point.raw - meanRaw) * (point.referenceMgdL - meanRef)
                variance += weight * (point.raw - meanRaw) * (point.raw - meanRaw)
            }
            // Only a positive relation between raw signal and fingersticks gives a slope. Points that
            // contradict each other (a contaminated finger, a stick during a fast change) would be
            // clamped to the flattest slope and squeeze every value toward the mean, showing lows as
            // in range. Then the default slope stays and only the offset is fitted.
            if variance > 0, covariance > 0 {
                slope = min(max(covariance / variance, slopeRange.lowerBound), slopeRange.upperBound)
            }
        }
        let intercept = min(max(meanRef - slope * meanRaw, interceptRange.lowerBound), interceptRange.upperBound)
        return Calibration(slope: slope, intercept: intercept, pointCount: recent.count, lastCalibration: last)
    }
}

/// A fingerstick measurement, optionally used for calibration.
public struct FingerstickEntry: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var date: Date
    public var mgdL: Double
    public var usedForCalibration: Bool
    public var sensorSerial: String?
    /// The calibration point this fingerstick added, so deleting it can undo the calibration.
    public var calibrationPointID: UUID?
    /// What LibreLink (or the reader) showed at the same moment, if typed in, to compare accuracy.
    public var libreLinkMgdL: Double?

    public init(id: UUID = UUID(), date: Date, mgdL: Double, usedForCalibration: Bool, sensorSerial: String? = nil,
                calibrationPointID: UUID? = nil, libreLinkMgdL: Double? = nil) {
        self.id = id
        self.date = date
        self.mgdL = mgdL
        self.usedForCalibration = usedForCalibration
        self.sensorSerial = sensorSerial
        self.calibrationPointID = calibrationPointID
        self.libreLinkMgdL = libreLinkMgdL
    }
}

/// What happened to a fingerstick offered for calibration.
public enum CalibrationOutcome: Equatable, Sendable {
    /// Used: the new calibration applies. `pointID` identifies the calibration point.
    case applied(pointID: UUID)
    /// The sensor is still warming up; its signal isn't reliable yet.
    case warmingUp
    /// Far from what the sensor shows (`sensorMgdL`). Not used until a second fingerstick agrees.
    case needsConfirmation(sensorMgdL: Double)
}
