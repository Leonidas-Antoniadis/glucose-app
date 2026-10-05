import Foundation

/// Meal, insulin, exercise and free-text notes.
public struct LogEntry: Codable, Hashable, Identifiable, Sendable {
    public enum Kind: Codable, Hashable, Sendable {
        case meal(carbsGrams: Double?)
        case insulin(units: Double, type: InsulinType)
        case exercise(minutes: Int)
        case note
    }

    public enum InsulinType: String, Codable, CaseIterable, Sendable {
        case rapid, long, other

        public var displayName: String {
            switch self {
            case .rapid: return "Fast-acting insulin"
            case .long: return "Slow-acting insulin"
            case .other: return "Insulin"
            }
        }
    }

    public var id: UUID
    public var date: Date
    public var kind: Kind
    public var text: String

    public init(id: UUID = UUID(), date: Date, kind: Kind, text: String = "") {
        self.id = id
        self.date = date
        self.kind = kind
        self.text = text
    }

    public var title: String {
        switch kind {
        case .meal(let carbs): return carbs.map { "Food · \(Self.format($0)) g carbs" } ?? "Food"
        case .insulin(let units, let type): return "\(type.displayName) · \(Self.format(units)) U"
        case .exercise(let minutes): return "Exercise · \(minutes) min"
        case .note: return "Note"
        }
    }

    public var symbolName: String {
        switch kind {
        case .meal: return "fork.knife"
        case .insulin: return "syringe"
        case .exercise: return "figure.run"
        case .note: return "note.text"
        }
    }

    public var csvKind: String {
        switch kind {
        case .meal: return "meal"
        case .insulin: return "insulin"
        case .exercise: return "exercise"
        case .note: return "note"
        }
    }

    public var csvAmount: String {
        switch kind {
        case .meal(let carbs): return carbs.map(Self.format) ?? ""
        case .insulin(let units, _): return Self.format(units)
        case .exercise(let minutes): return String(minutes)
        case .note: return ""
        }
    }

    static func format(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }
}

public enum CSVExport {
    private static let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    public static func readings(_ readings: [GlucoseReading]) -> String {
        var lines = ["timestamp,glucose_mgdl,glucose_mmoll,source,sensor"]
        for reading in readings.sorted(by: { $0.timestamp < $1.timestamp }) {
            let mmol = String(format: "%.1f", GlucoseUnit.mmolL.fromMgdL(reading.mgdL))
            lines.append("\(iso.string(from: reading.timestamp)),\(Int(reading.mgdL.rounded())),\(mmol),\(reading.source.rawValue),\(escape(reading.sensorSerial))")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    public static func logbook(_ entries: [LogEntry]) -> String {
        var lines = ["timestamp,kind,amount,text"]
        for entry in entries.sorted(by: { $0.date < $1.date }) {
            lines.append("\(iso.string(from: entry.date)),\(entry.csvKind),\(entry.csvAmount),\(escape(entry.text))")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    public static func fingersticks(_ entries: [FingerstickEntry]) -> String {
        var lines = ["timestamp,glucose_mgdl,used_for_calibration"]
        for entry in entries.sorted(by: { $0.date < $1.date }) {
            lines.append("\(iso.string(from: entry.date)),\(Int(entry.mgdL.rounded())),\(entry.usedForCalibration)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Quotes a field if it contains a comma, quote or newline.
    static func escape(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
