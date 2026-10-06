import Foundation

/// Display unit. All values are stored internally as mg/dL (the sensor's native unit).
public enum GlucoseUnit: String, Codable, CaseIterable, Sendable {
    case mgdL
    case mmolL

    /// mg/dL per mmol/L, from the molar mass of glucose (180.16 g/mol).
    public static let mgdLPerMmolL = 18.016

    public var symbol: String {
        switch self {
        case .mgdL: return "mg/dL"
        case .mmolL: return "mmol/L"
        }
    }

    /// Converts a stored mg/dL value into this unit.
    public func fromMgdL(_ value: Double) -> Double {
        switch self {
        case .mgdL: return value
        case .mmolL: return value / Self.mgdLPerMmolL
        }
    }

    /// Converts a value entered in this unit back into mg/dL.
    public func toMgdL(_ value: Double) -> Double {
        switch self {
        case .mgdL: return value
        case .mmolL: return value * Self.mgdLPerMmolL
        }
    }

    /// Formats a stored mg/dL value: whole numbers for mg/dL, one decimal for mmol/L.
    public func format(mgdL value: Double, includeSymbol: Bool = false) -> String {
        let number: String
        switch self {
        case .mgdL: number = String(Int(value.rounded()))
        case .mmolL: number = String(format: "%.1f", fromMgdL(value))
        }
        return includeSymbol ? "\(number) \(symbol)" : number
    }

    /// Formats a sensor reading: like `format`, but LO and HI at the ends of the sensor's range.
    public func formatReading(mgdL value: Double, includeSymbol: Bool = false) -> String {
        if value <= ReadingPipeline.lowMgdL { return "LO" }
        if value >= ReadingPipeline.highMgdL { return "HI" }
        return format(mgdL: value, includeSymbol: includeSymbol)
    }

    /// Formats a rate of change given in mg/dL per minute: one decimal in mg/dL/min, two in
    /// mmol/L/min (1.5 mg/dL/min is 0.08 mmol/L/min, which one decimal would round to 0.1).
    public func formatRate(mgdLPerMinute rate: Double) -> String {
        switch self {
        case .mgdL: return String(format: "%.1f mg/dL/min", rate)
        case .mmolL: return String(format: "%.2f mmol/L/min", fromMgdL(rate))
        }
    }

    /// Step size for threshold editors in this unit, expressed in mg/dL.
    public var editorStepMgdL: Double {
        switch self {
        case .mgdL: return 1
        case .mmolL: return 0.1 * Self.mgdLPerMmolL
        }
    }
}
