import Foundation

/// One sensor you wore, kept so its IDs are at hand when you contact the manufacturer's support.
public struct SensorHistoryEntry: Codable, Hashable, Identifiable, Sendable {
    public enum EndReason: String, Codable, CaseIterable, Identifiable, Sendable {
        case expired, failed, fellOff, removedEarly, replaced, other

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .expired: return "Ended normally"
            case .failed: return "Sensor error"
            case .fellOff: return "Fell off"
            case .removedEarly: return "Removed early"
            case .replaced: return "Replaced"
            case .other: return "Other"
            }
        }
    }

    public var id: String
    public var sensorType: String
    /// Serial derived from the sensor ID by this app.
    public var computedSerial: String
    /// Serial printed on the box or applicator, typed in by you.
    public var printedSerial: String
    public var uidHex: String
    public var patchInfoHex: String
    public var startedAt: Date?
    public var pairedAt: Date?
    public var expectedEnd: Date?
    public var endedAt: Date?
    public var endReason: EndReason?
    public var note: String

    public init(id: String = UUID().uuidString, sensorType: String, computedSerial: String = "", printedSerial: String = "",
                uidHex: String = "", patchInfoHex: String = "", startedAt: Date? = nil, pairedAt: Date? = nil,
                expectedEnd: Date? = nil, endedAt: Date? = nil, endReason: EndReason? = nil, note: String = "") {
        self.id = id
        self.sensorType = sensorType
        self.computedSerial = computedSerial
        self.printedSerial = printedSerial
        self.uidHex = uidHex
        self.patchInfoHex = patchInfoHex
        self.startedAt = startedAt
        self.pairedAt = pairedAt
        self.expectedEnd = expectedEnd
        self.endedAt = endedAt
        self.endReason = endReason
        self.note = note
    }

    public var isActive: Bool { endedAt == nil }

    /// Plain-text summary to paste into an email or read out on a support call.
    public func supportText(dateStyle: (Date) -> String = { ISO8601DateFormatter().string(from: $0) }) -> String {
        var lines = ["Sensor: \(sensorType)"]
        if !printedSerial.isEmpty { lines.append("Serial (printed): \(printedSerial)") }
        if !computedSerial.isEmpty { lines.append("Serial (from sensor ID): \(computedSerial)") }
        if !uidHex.isEmpty { lines.append("Sensor UID: \(uidHex)") }
        if let startedAt { lines.append("Started: \(dateStyle(startedAt))") }
        if let endedAt { lines.append("Ended: \(dateStyle(endedAt))") }
        if let endReason { lines.append("Reason: \(endReason.title)") }
        if let startedAt, let end = endedAt {
            lines.append(String(format: "Worn: %.1f days", end.timeIntervalSince(startedAt) / 86_400))
        }
        if !note.isEmpty { lines.append("Note: \(note)") }
        return lines.joined(separator: "\n")
    }
}

/// The most recent sensors, newest first.
public struct SensorHistory: Codable, Hashable, Sendable {
    public static let limit = 5
    public private(set) var entries: [SensorHistoryEntry]

    public init(entries: [SensorHistoryEntry] = []) {
        self.entries = Array(entries.prefix(Self.limit))
    }

    /// Adds a sensor (or refreshes it if it's already known, keeping your typed-in details).
    /// Any other sensor that is still open is marked as replaced.
    public mutating func record(_ entry: SensorHistoryEntry, at date: Date) {
        var merged = entry
        if let index = entries.firstIndex(where: { $0.id == entry.id }) {
            let existing = entries.remove(at: index)
            merged.printedSerial = existing.printedSerial.isEmpty ? entry.printedSerial : existing.printedSerial
            merged.note = existing.note.isEmpty ? entry.note : existing.note
            merged.endedAt = existing.endedAt
            merged.endReason = existing.endReason
            merged.pairedAt = existing.pairedAt ?? entry.pairedAt
        }
        for index in entries.indices where entries[index].isActive {
            entries[index].endedAt = date
            entries[index].endReason = .replaced
        }
        entries.insert(merged, at: 0)
        if entries.count > Self.limit {
            entries.removeLast(entries.count - Self.limit)
        }
    }

    public mutating func update(_ entry: SensorHistoryEntry) {
        if let index = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[index] = entry
        }
    }

    /// Marks a sensor as ended, unless it already has an end recorded.
    public mutating func markEnded(id: String, at date: Date, reason: SensorHistoryEntry.EndReason) {
        guard let index = entries.firstIndex(where: { $0.id == id }), entries[index].endedAt == nil else { return }
        entries[index].endedAt = date
        entries[index].endReason = reason
    }

    public mutating func remove(id: String) {
        entries.removeAll { $0.id == id }
    }
}
