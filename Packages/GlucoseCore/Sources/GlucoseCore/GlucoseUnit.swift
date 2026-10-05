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

    /// Step size for threshold editors in this unit, expressed in mg/dL.
    public var editorStepMgdL: Double {
        switch self {
        case .mgdL: return 1
        case .mmolL: return 0.1 * Self.mgdLPerMmolL
        }
    }
}
