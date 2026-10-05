import Foundation
@testable import LibreProtocol

/// Builds synthetic, internally consistent sensor data. These fixtures check that parsing,
/// CRCs and the cipher fit together; they are not captures from a real sensor.
enum LibreFixtures {
    /// Sensor byte order: uid[7] = 0xE0, uid[6] = 0x07.
    static let uid: [UInt8] = [0x5C, 0x6F, 0x0A, 0x00, 0x00, 0xA0, 0x07, 0xE0]
    /// Libre 2 Plus EU style patch info.
    static let patchInfo: [UInt8] = [0xC6, 0x09, 0x31, 0x01, 0x0B, 0x5E]

    static func writeFRAMRecord(_ bytes: inout [UInt8], offset: Int, raw: Int, temperature: Int = 6000) {
        LibreBits.write(raw, into: &bytes, byteOffset: offset, bitOffset: 0, bitCount: 0xE)
        LibreBits.write(temperature >> 2, into: &bytes, byteOffset: offset, bitOffset: 0x1A, bitCount: 0xC)
    }

    /// Plain FRAM where trend slot values are `1000 + minutesAgo` and history `2000 + 15-minute steps ago`.
    static func plainFRAM(age: Int, state: UInt8 = 3, maxLife: Int = 21_600, trendIndex: Int = 5, historyIndex: Int = 9) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 344)
        bytes[4] = state
        bytes[26] = UInt8(trendIndex)
        bytes[27] = UInt8(historyIndex)
        for i in 0..<16 {
            let slot = (trendIndex - 1 - i + 32) % 16
            writeFRAMRecord(&bytes, offset: 28 + slot * 6, raw: 1000 + i)
        }
        for j in 0..<32 {
            let slot = (historyIndex - 1 - j + 64) % 32
            writeFRAMRecord(&bytes, offset: 124 + slot * 6, raw: 2000 + j)
        }
        bytes[316] = UInt8(age & 0xFF)
        bytes[317] = UInt8(age >> 8)
        bytes[326] = UInt8(maxLife & 0xFF)
        bytes[327] = UInt8(maxLife >> 8)

        var header = Array(bytes[0..<24]); LibreCRC.sealFirstTwoBytes(&header)
        var body = Array(bytes[24..<320]); LibreCRC.sealFirstTwoBytes(&body)
        var footer = Array(bytes[320..<344]); LibreCRC.sealFirstTwoBytes(&footer)
        return header + body + footer
    }

    /// Plain 44-byte BLE payload: trend values `1500 + i`, history `2500 + i`.
    static func plainBLE(age: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 44)
        for i in 0..<10 {
            let raw = i < 7 ? 1500 + i : 2500 + (i - 7)
            LibreBits.write(raw, into: &bytes, byteOffset: i * 4, bitOffset: 0, bitCount: 0xE)
            LibreBits.write(1500, into: &bytes, byteOffset: i * 4, bitOffset: 0xE, bitCount: 0xC)
        }
        bytes[40] = UInt8(age & 0xFF)
        bytes[41] = UInt8(age >> 8)
        LibreCRC.sealLastTwoBytes(&bytes)
        return bytes
    }
}
