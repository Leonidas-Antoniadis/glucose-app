import Foundation

/// One raw sensor measurement. `raw` is the uncalibrated 14-bit glucose signal.
public struct LibreRawReading: Hashable, Sendable {
    public let minuteIndex: Int
    public let raw: Int
    public let rawTemperature: Int
    public let temperatureAdjustment: Int
    public let hasError: Bool
    /// From the 15-minute history rather than the 1-minute trend.
    public let isHistory: Bool
}

/// Decrypted 344-byte FRAM read over NFC: sensor state, age, 16 minutes of trend and 8 hours of history.
public struct LibreFRAM: Sendable {
    public enum State: UInt8, Codable, Sendable {
        case unknown = 0
        case notActivated = 1
        case warmingUp = 2
        case active = 3
        case expired = 4
        case shutdown = 5
        case failure = 6

        public var description: String {
            switch self {
            case .unknown: return "Unknown"
            case .notActivated: return "Not activated"
            case .warmingUp: return "Warming up"
            case .active: return "Active"
            case .expired: return "Expired"
            case .shutdown: return "Shut down"
            case .failure: return "Failed"
            }
        }
    }

    public static let size = 344
    public static let trendOffset = 28
    public static let historyOffset = 124

    public let state: State
    public let ageMinutes: Int
    /// Maximum wear time in minutes, as stored by the sensor (0 if not set).
    public let maxLifeMinutes: Int
    /// Most recent first.
    public let trend: [LibreRawReading]
    /// Most recent first.
    public let history: [LibreRawReading]

    /// The sensor state from the FRAM header alone. A sensor that was never started may not have
    /// valid data in the rest of the FRAM yet, so this checks only the header's checksum.
    public static func state(decrypted bytes: [UInt8]) throws -> State {
        guard bytes.count >= 24 else { throw LibreProtocolError.invalidLength(expected: 24, actual: bytes.count) }
        guard LibreCRC.hasValidCRCInFirstTwoBytes(Array(bytes[0..<24])) else { throw LibreProtocolError.invalidCRC("FRAM header") }
        return State(rawValue: bytes[4]) ?? .unknown
    }

    public init(decrypted bytes: [UInt8]) throws {
        guard bytes.count >= Self.size else {
            throw LibreProtocolError.invalidLength(expected: Self.size, actual: bytes.count)
        }
        guard LibreCRC.hasValidCRCInFirstTwoBytes(Array(bytes[0..<24])) else { throw LibreProtocolError.invalidCRC("FRAM header") }
        guard LibreCRC.hasValidCRCInFirstTwoBytes(Array(bytes[24..<320])) else { throw LibreProtocolError.invalidCRC("FRAM body") }
        guard LibreCRC.hasValidCRCInFirstTwoBytes(Array(bytes[320..<344])) else { throw LibreProtocolError.invalidCRC("FRAM footer") }

        state = State(rawValue: bytes[4]) ?? .unknown
        ageMinutes = Int(bytes[316]) | Int(bytes[317]) << 8
        maxLifeMinutes = Int(bytes[326]) | Int(bytes[327]) << 8

        let trendIndex = Int(bytes[26]) % 16
        let historyIndex = Int(bytes[27]) % 32
        let age = ageMinutes

        trend = (0..<16).compactMap { i in
            let slot = (trendIndex - 1 - i + 32) % 16
            return Self.record(bytes, offset: Self.trendOffset + slot * 6, minute: age - i, isHistory: false)
        }

        let lastHistoryMinute = max(0, (age - 3) / 15 * 15)
        history = (0..<32).compactMap { j in
            let slot = (historyIndex - 1 - j + 64) % 32
            return Self.record(bytes, offset: Self.historyOffset + slot * 6, minute: lastHistoryMinute - j * 15, isHistory: true)
        }
    }

    static func record(_ bytes: [UInt8], offset: Int, minute: Int, isHistory: Bool) -> LibreRawReading? {
        let raw = LibreBits.read(bytes, byteOffset: offset, bitOffset: 0, bitCount: 0xE)
        guard raw > 0, minute >= 0 else { return nil }
        var adjustment = LibreBits.read(bytes, byteOffset: offset, bitOffset: 0x26, bitCount: 0x9) << 2
        if LibreBits.read(bytes, byteOffset: offset, bitOffset: 0x2F, bitCount: 1) != 0 { adjustment = -adjustment }
        return LibreRawReading(
            minuteIndex: minute,
            raw: raw,
            rawTemperature: LibreBits.read(bytes, byteOffset: offset, bitOffset: 0x1A, bitCount: 0xC) << 2,
            temperatureAdjustment: adjustment,
            hasError: LibreBits.read(bytes, byteOffset: offset, bitOffset: 0x19, bitCount: 1) != 0,
            isHistory: isHistory
        )
    }
}

/// Decrypted 44-byte Bluetooth packet: 7 recent readings, 3 history readings, the sensor age and a CRC.
public struct LibreBLEPacket: Sendable {
    public static let decryptedSize = 44
    /// Minutes before `ageMinutes` for the seven trend readings.
    public static let trendOffsets = [0, 2, 4, 6, 7, 12, 15]

    public let ageMinutes: Int
    /// The seven trend readings, most recent first.
    public let trend: [LibreRawReading]
    /// The three history readings (15-minute spacing), most recent first.
    public let history: [LibreRawReading]

    public var latest: LibreRawReading? { trend.first }

    public init(decrypted bytes: [UInt8]) throws {
        guard bytes.count >= Self.decryptedSize else {
            throw LibreProtocolError.invalidLength(expected: Self.decryptedSize, actual: bytes.count)
        }
        let age = Int(bytes[40]) | Int(bytes[41]) << 8
        ageMinutes = age

        var trend: [LibreRawReading] = []
        var history: [LibreRawReading] = []
        let lastHistoryMinute = (age - 3) / 15 * 15
        for i in 0..<10 {
            let isHistory = i >= 7
            let minute = isHistory ? lastHistoryMinute - (i - 7) * 15 : age - Self.trendOffsets[i]
            let offset = i * 4
            let raw = LibreBits.read(bytes, byteOffset: offset, bitOffset: 0, bitCount: 0xE)
            guard raw > 0, minute >= 0 else { continue }
            var adjustment = LibreBits.read(bytes, byteOffset: offset, bitOffset: 0x1A, bitCount: 0x5) << 2
            if LibreBits.read(bytes, byteOffset: offset, bitOffset: 0x1F, bitCount: 1) != 0 { adjustment = -adjustment }
            let reading = LibreRawReading(
                minuteIndex: minute,
                raw: raw,
                rawTemperature: LibreBits.read(bytes, byteOffset: offset, bitOffset: 0xE, bitCount: 0xC) << 2,
                temperatureAdjustment: adjustment,
                hasError: false,
                isHistory: isHistory
            )
            if isHistory { history.append(reading) } else { trend.append(reading) }
        }
        self.trend = trend
        self.history = history
    }
}
