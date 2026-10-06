import Foundation

/// Sensor family, identified from the first bytes of the NFC patch info.
public enum LibreSensorType: String, Codable, CaseIterable, Sendable {
    case libre1
    case libreUS14Day
    case libre2EU
    case libre2PlusEU
    case libre2US
    case libre2CA
    case libre2Gen2
    case unknown

    public init(patchInfo: [UInt8]) {
        guard let first = patchInfo.first else { self = .unknown; return }
        switch first {
        case 0xDF, 0xA2: self = .libre1
        case 0xE5, 0xE6: self = .libreUS14Day
        case 0x9D, 0xC5: self = .libre2EU
        case 0xC6: self = .libre2PlusEU
        // European Libre 2 and 2 Plus sold since mid-2025 (same protocol, per DiaBLE):
        // 7F 0E 30 01 is a Libre 2, 7F 0E 31 01 a Libre 2 Plus.
        case 0x7F: self = patchInfo.count > 2 && patchInfo[2] & 0x0F != 0 ? .libre2PlusEU : .libre2EU
        case 0x76:
            switch patchInfo.count > 3 ? patchInfo[3] : 0 {
            case 0x02: self = .libre2US
            case 0x04: self = .libre2CA
            default: self = .unknown
            }
        case 0x2B, 0x2C, 0x2D, 0x2E: self = .libre2Gen2
        default: self = .unknown
        }
    }

    /// Only European Libre 2 / 2 Plus sensors use the protocol implemented here.
    public var isSupported: Bool {
        self == .libre2EU || self == .libre2PlusEU
    }

    public var displayName: String {
        switch self {
        case .libre1: return "Libre 1"
        case .libreUS14Day: return "Libre 14-day (US)"
        case .libre2EU: return "Libre 2 (EU)"
        case .libre2PlusEU: return "Libre 2 Plus (EU)"
        case .libre2US: return "Libre 2 (US)"
        case .libre2CA: return "Libre 2 (CA)"
        case .libre2Gen2: return "Libre 2 Gen2"
        case .unknown: return "Unknown sensor"
        }
    }

    /// Nominal wear time, used when the FRAM doesn't provide one.
    public var lifetimeMinutes: Int {
        switch self {
        case .libre2PlusEU: return 15 * 24 * 60
        default: return 14 * 24 * 60
        }
    }
}

public enum LibreSerial {
    private static let alphabet = Array("0123456789ACDEFGHJKLMNPQRTUVWXYZ")

    /// Serial number derived from the UID (sensor byte order). Shown as "computed" in the UI,
    /// so it can be compared with the serial printed on the applicator.
    public static func serial(uid: [UInt8], patchInfo: [UInt8]) -> String {
        guard uid.count == 8 else { return "" }
        // Unique part, most significant byte first: uid[5] ... uid[0].
        var bits: [Int] = []
        for byte in uid[0...5].reversed() {
            for shift in stride(from: 7, through: 0, by: -1) {
                bits.append(Int(byte >> UInt8(shift)) & 1)
            }
        }
        bits += [0, 0]
        var characters = ""
        for group in 0..<10 {
            let value = bits[group * 5..<group * 5 + 5].reduce(0) { $0 << 1 | $1 }
            characters.append(alphabet[value])
        }
        let family = patchInfo.count > 2 ? Int(patchInfo[2] >> 4) : 0
        return "\(family)" + characters
    }
}

public extension Array where Element == UInt8 {
    var hexString: String {
        map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    init?(hexString: String) {
        let cleaned = hexString.filter { $0.isHexDigit }
        guard cleaned.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            guard let byte = UInt8(cleaned[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self = bytes
    }
}
