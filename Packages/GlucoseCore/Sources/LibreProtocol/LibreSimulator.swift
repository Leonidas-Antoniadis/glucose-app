import Foundation

/// Builds byte-exact, encrypted Libre 2 data from glucose values, so the demo mode and tests can
/// run the real decoding pipeline. It produces what a sensor *would* send under the documented
/// protocol; it is not a capture of a real sensor.
public enum LibreSimulator {
    /// A made-up sensor ID in sensor byte order.
    public static let demoUID: [UInt8] = [0x5C, 0x6F, 0x0A, 0x00, 0x00, 0xA0, 0x07, 0xE0]
    /// Libre 2 Plus (EU) style patch info.
    public static let demoPatchInfo: [UInt8] = [0xC6, 0x09, 0x31, 0x01, 0x0B, 0x5E]
    public static let defaultTemperature = 6000

    /// Plain 44-byte BLE payload for a sensor of age `ageMinutes`; `raw` gives the raw value per minute.
    public static func blePlaintext(ageMinutes: Int, temperature: Int = defaultTemperature, raw: (Int) -> Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: LibreBLEPacket.decryptedSize)
        let lastHistory = (ageMinutes - 2) / 15 * 15
        for i in 0..<10 {
            let minute = i < 7 ? ageMinutes - LibreBLEPacket.trendOffsets[i] : lastHistory - (i - 7) * 15
            let value = min(max(raw(max(0, minute)), 0), 0x3FFF)
            LibreBits.write(value, into: &bytes, byteOffset: i * 4, bitOffset: 0, bitCount: 0xE)
            LibreBits.write(temperature >> 2, into: &bytes, byteOffset: i * 4, bitOffset: 0xE, bitCount: 0xC)
        }
        bytes[40] = UInt8(ageMinutes & 0xFF)
        bytes[41] = UInt8((ageMinutes >> 8) & 0xFF)
        LibreCRC.sealLastTwoBytes(&bytes)
        return bytes
    }

    /// Encrypted 46-byte BLE packet, as it arrives over Bluetooth.
    public static func blePacket(uid: [UInt8] = demoUID, ageMinutes: Int, temperature: Int = defaultTemperature,
                                 raw: (Int) -> Int) throws -> [UInt8] {
        let seed = (UInt8(truncatingIfNeeded: ageMinutes &* 37), UInt8(truncatingIfNeeded: ageMinutes &* 11 &+ 5))
        return try Libre2Crypto.encryptBLE(uid: uid, plaintext: blePlaintext(ageMinutes: ageMinutes, temperature: temperature, raw: raw), seed: seed)
    }

    /// Plain 344-byte FRAM with 16 minutes of trend and 8 hours of history.
    public static func framPlaintext(ageMinutes: Int, state: LibreFRAM.State = .active, maxLifeMinutes: Int = 15 * 1440,
                                     temperature: Int = defaultTemperature, raw: (Int) -> Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: LibreFRAM.size)
        let trendIndex = ageMinutes % 16
        let lastHistory = max(0, (ageMinutes - 3) / 15 * 15)
        let historyIndex = (lastHistory / 15 + 1) % 32
        bytes[4] = state.rawValue
        bytes[26] = UInt8(trendIndex)
        bytes[27] = UInt8(historyIndex)

        func write(_ value: Int, at offset: Int) {
            LibreBits.write(min(max(value, 0), 0x3FFF), into: &bytes, byteOffset: offset, bitOffset: 0, bitCount: 0xE)
            LibreBits.write(temperature >> 2, into: &bytes, byteOffset: offset, bitOffset: 0x1A, bitCount: 0xC)
        }
        for i in 0..<16 where ageMinutes - i >= 0 {
            let slot = (trendIndex - 1 - i + 32) % 16
            write(raw(ageMinutes - i), at: LibreFRAM.trendOffset + slot * 6)
        }
        for j in 0..<32 where lastHistory - j * 15 >= 0 {
            let slot = (historyIndex - 1 - j + 64) % 32
            write(raw(lastHistory - j * 15), at: LibreFRAM.historyOffset + slot * 6)
        }
        bytes[316] = UInt8(ageMinutes & 0xFF)
        bytes[317] = UInt8((ageMinutes >> 8) & 0xFF)
        bytes[326] = UInt8(maxLifeMinutes & 0xFF)
        bytes[327] = UInt8((maxLifeMinutes >> 8) & 0xFF)

        var header = Array(bytes[0..<24]); LibreCRC.sealFirstTwoBytes(&header)
        var body = Array(bytes[24..<320]); LibreCRC.sealFirstTwoBytes(&body)
        var footer = Array(bytes[320..<344]); LibreCRC.sealFirstTwoBytes(&footer)
        return header + body + footer
    }

    /// Encrypted FRAM, as read over NFC.
    public static func fram(uid: [UInt8] = demoUID, patchInfo: [UInt8] = demoPatchInfo, ageMinutes: Int,
                            raw: (Int) -> Int) throws -> [UInt8] {
        // The FRAM cipher is a XOR stream, so "decrypting" plain data encrypts it.
        try Libre2Crypto.decryptFRAM(uid: uid, patchInfo: patchInfo, data: framPlaintext(ageMinutes: ageMinutes, raw: raw))
    }
}

/// Byte layout of Libre data, for the raw-data inspector.
public enum LibreLayout {
    public struct Region: Hashable, Sendable {
        public let range: Range<Int>
        public let name: String
        public let detail: String

        public init(range: Range<Int>, name: String, detail: String) {
            self.range = range
            self.name = name
            self.detail = detail
        }
    }

    /// The 46-byte packet as received.
    public static let blePacket: [Region] = [
        Region(range: 0..<2, name: "Seed", detail: "Sent in the clear; seeds the decryption key stream"),
        Region(range: 2..<46, name: "Encrypted", detail: "44 bytes encrypted with a key derived from the sensor ID"),
    ]

    /// The 44 bytes after decryption.
    public static let bleDecrypted: [Region] = [
        Region(range: 0..<28, name: "Trend", detail: "7 readings, 4 bytes each: now, −2, −4, −6, −7, −12, −15 min"),
        Region(range: 28..<40, name: "History", detail: "3 readings at 15-minute marks"),
        Region(range: 40..<42, name: "Sensor age", detail: "Minutes since the sensor started (little-endian)"),
        Region(range: 42..<44, name: "CRC", detail: "Checksum; a mismatch means a corrupt packet or another sensor"),
    ]

    /// The 344-byte FRAM after decryption.
    public static let fram: [Region] = [
        Region(range: 0..<24, name: "Header", detail: "CRC (bytes 0-1) and sensor state (byte 4)"),
        Region(range: 24..<28, name: "Body CRC + indexes", detail: "CRC (24-25), next trend slot (26), next history slot (27)"),
        Region(range: 28..<124, name: "Trend", detail: "16 one-minute readings, 6 bytes each (ring buffer)"),
        Region(range: 124..<316, name: "History", detail: "32 fifteen-minute readings, 6 bytes each (8 hours)"),
        Region(range: 316..<320, name: "Sensor age", detail: "Minutes since start (316-317)"),
        Region(range: 320..<344, name: "Footer", detail: "CRC (320-321) and maximum life in minutes (326-327)"),
    ]

    public static func region(of index: Int, in regions: [Region]) -> Region? {
        regions.first { $0.range.contains(index) }
    }
}
