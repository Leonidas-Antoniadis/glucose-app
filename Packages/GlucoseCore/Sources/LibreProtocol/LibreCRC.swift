import Foundation

/// CRC used by FreeStyle Libre FRAM sections and BLE packets: CRC-16 with the reflected
/// CCITT polynomial (0x8408), initial value 0xFFFF, and the result bit-reversed.
public enum LibreCRC {
    private static let table: [UInt16] = (0..<256).map { index in
        var crc = UInt16(index)
        for _ in 0..<8 {
            crc = crc & 1 != 0 ? (crc >> 1) ^ 0x8408 : crc >> 1
        }
        return crc
    }

    public static func crc16<C: Collection>(_ bytes: C) -> UInt16 where C.Element == UInt8 {
        var crc: UInt16 = 0xFFFF
        for byte in bytes {
            crc = (crc >> 8) ^ table[Int((crc ^ UInt16(byte)) & 0xFF)]
        }
        var reversed: UInt16 = 0
        for _ in 0..<16 {
            reversed = (reversed << 1) | (crc & 1)
            crc >>= 1
        }
        return reversed
    }

    /// FRAM sections store their CRC little-endian in the first two bytes (low byte first),
    /// as DiaBLE reads it and as real captures confirm.
    public static func hasValidCRCInFirstTwoBytes(_ bytes: [UInt8]) -> Bool {
        guard bytes.count > 2 else { return false }
        return crc16(bytes.dropFirst(2)) == (UInt16(bytes[1]) << 8 | UInt16(bytes[0]))
    }

    /// BLE packets store their CRC in the last two bytes (high byte last).
    public static func hasValidCRCInLastTwoBytes(_ bytes: [UInt8]) -> Bool {
        let count = bytes.count
        guard count > 2 else { return false }
        return crc16(bytes.dropLast(2)) == (UInt16(bytes[count - 1]) << 8 | UInt16(bytes[count - 2]))
    }

    /// Writes a valid CRC into the first two bytes (used to build test fixtures).
    public static func sealFirstTwoBytes(_ bytes: inout [UInt8]) {
        let crc = crc16(bytes.dropFirst(2))
        bytes[0] = UInt8(crc & 0xFF)
        bytes[1] = UInt8(crc >> 8)
    }

    /// Writes a valid CRC into the last two bytes (used to build test fixtures).
    public static func sealLastTwoBytes(_ bytes: inout [UInt8]) {
        let count = bytes.count
        let crc = crc16(bytes.dropLast(2))
        bytes[count - 1] = UInt8(crc >> 8)
        bytes[count - 2] = UInt8(crc & 0xFF)
    }
}

/// Reads little-endian bit fields, least significant bit first, as Libre records are packed.
public enum LibreBits {
    public static func read(_ buffer: [UInt8], byteOffset: Int, bitOffset: Int, bitCount: Int) -> Int {
        var result = 0
        for i in 0..<bitCount {
            let totalBitOffset = byteOffset * 8 + bitOffset + i
            let byteIndex = totalBitOffset / 8
            let bit = totalBitOffset % 8
            guard byteIndex >= 0, byteIndex < buffer.count else { continue }
            if (buffer[byteIndex] >> bit) & 1 == 1 {
                result |= 1 << i
            }
        }
        return result
    }

    /// Writes a bit field (used to build test fixtures).
    public static func write(_ value: Int, into buffer: inout [UInt8], byteOffset: Int, bitOffset: Int, bitCount: Int) {
        for i in 0..<bitCount {
            let totalBitOffset = byteOffset * 8 + bitOffset + i
            let byteIndex = totalBitOffset / 8
            let bit = UInt8(totalBitOffset % 8)
            if (value >> i) & 1 == 1 {
                buffer[byteIndex] |= 1 << bit
            } else {
                buffer[byteIndex] &= ~(1 << bit)
            }
        }
    }
}
