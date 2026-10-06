import XCTest
import GlucoseCore
@testable import LibreProtocol

final class LibreProtocolTests: XCTestCase {
    // MARK: CRC and bits

    func testCRCMatchesReferenceCheckValue() {
        // CRC-16/MCRF4XX of "123456789" is 0x6F91; Libre's variant returns it bit-reversed.
        XCTAssertEqual(LibreCRC.crc16(Array("123456789".utf8)), 0x89F6)
    }

    func testCRCSealAndValidate() {
        var first: [UInt8] = [0, 0, 1, 2, 3, 4, 5]
        LibreCRC.sealFirstTwoBytes(&first)
        XCTAssertTrue(LibreCRC.hasValidCRCInFirstTwoBytes(first))
        XCTAssertEqual(UInt16(first[1]) << 8 | UInt16(first[0]), LibreCRC.crc16(first.dropFirst(2)), "FRAM CRC is low byte first")
        first[4] ^= 0xFF
        XCTAssertFalse(LibreCRC.hasValidCRCInFirstTwoBytes(first))

        var last: [UInt8] = [9, 8, 7, 6, 0, 0]
        LibreCRC.sealLastTwoBytes(&last)
        XCTAssertTrue(LibreCRC.hasValidCRCInLastTwoBytes(last))
    }

    func testBitsAreLeastSignificantFirst() {
        let buffer: [UInt8] = [0b1010_1100, 0b0000_0011]
        XCTAssertEqual(LibreBits.read(buffer, byteOffset: 0, bitOffset: 2, bitCount: 3), 0b011)
        XCTAssertEqual(LibreBits.read(buffer, byteOffset: 0, bitOffset: 6, bitCount: 4), 0b1110)
        var written = [UInt8](repeating: 0, count: 3)
        LibreBits.write(0x2AB, into: &written, byteOffset: 0, bitOffset: 5, bitCount: 12)
        XCTAssertEqual(LibreBits.read(written, byteOffset: 0, bitOffset: 5, bitCount: 12), 0x2AB)
    }

    // MARK: Sensor identification

    func testSensorTypes() {
        XCTAssertEqual(LibreSensorType(patchInfo: [0x9D, 0, 0, 0, 0, 0]), .libre2EU)
        XCTAssertEqual(LibreSensorType(patchInfo: [0xC5, 0, 0, 0, 0, 0]), .libre2EU)
        XCTAssertEqual(LibreSensorType(patchInfo: [0xC6, 0, 0, 0, 0, 0]), .libre2PlusEU)
        XCTAssertEqual(LibreSensorType(patchInfo: [0x7F, 0x0E, 0x31, 0x01, 0, 0]), .libre2PlusEU, "Libre 2 Plus EU since mid-2025")
        XCTAssertEqual(LibreSensorType(patchInfo: [0x7F, 0x0E, 0x30, 0x01, 0, 0]), .libre2EU, "Libre 2 EU since mid-2025")
        XCTAssertTrue(LibreSensorType(patchInfo: [0x7F, 0x0E, 0x31, 0x01, 0, 0]).isSupported)
        XCTAssertEqual(LibreSensorType(patchInfo: [0x76, 0, 0, 0x02, 0, 0]), .libre2US)
        XCTAssertEqual(LibreSensorType(patchInfo: [0xDF, 0, 0, 0, 0, 0]), .libre1)
        XCTAssertEqual(LibreSensorType(patchInfo: []), .unknown)
        XCTAssertTrue(LibreSensorType.libre2PlusEU.isSupported)
        XCTAssertFalse(LibreSensorType.libre2US.isSupported)
        XCTAssertEqual(LibreSensorType.libre2PlusEU.lifetimeMinutes, 15 * 1440)
    }

    func testSerialFormat() {
        let serial = LibreSerial.serial(uid: LibreFixtures.uid, patchInfo: LibreFixtures.patchInfo)
        XCTAssertEqual(serial.count, 11)
        XCTAssertEqual(serial.first, "3")
        XCTAssertTrue(serial.allSatisfy { "0123456789ACDEFGHJKLMNPQRTUVWXYZ".contains($0) })
    }

    func testHexRoundTrip() {
        let bytes: [UInt8] = [0x00, 0xAB, 0x7F]
        XCTAssertEqual(bytes.hexString, "00 AB 7F")
        XCTAssertEqual([UInt8](hexString: "00ab 7f"), bytes)
        XCTAssertNil([UInt8](hexString: "0"))
    }

    // MARK: Crypto

    func testCryptoIsDeterministicAndShaped() throws {
        let uid = LibreFixtures.uid
        let patch = LibreFixtures.patchInfo
        let enable = try Libre2Crypto.enableStreamingParameters(uid: uid, patchInfo: patch)
        XCTAssertEqual(enable.count, 9)
        XCTAssertEqual(enable[0], 0x1E)
        XCTAssertEqual(Array(enable[1...4]), [42, 0, 0, 0], "unlock code, little-endian")
        XCTAssertEqual(enable, try Libre2Crypto.enableStreamingParameters(uid: uid, patchInfo: patch))

        let first = try Libre2Crypto.streamingUnlockPayload(uid: uid, patchInfo: patch, unlockCount: 1)
        let second = try Libre2Crypto.streamingUnlockPayload(uid: uid, patchInfo: patch, unlockCount: 2)
        XCTAssertEqual(first.count, 12)
        XCTAssertEqual(Array(first.prefix(4)), [43, 0, 0, 0], "first 4 bytes are enableTime + unlockCount")
        XCTAssertNotEqual(first, second)
    }

    func testActivateParametersAreShaped() throws {
        let uid = LibreFixtures.uid
        let activate = try Libre2Crypto.activateParameters(uid: uid)
        XCTAssertEqual(activate.count, 5)
        XCTAssertEqual(activate[0], 0x1B)
        XCTAssertEqual(Array(activate.dropFirst()), Libre2Crypto.usefulFunction(uid: uid, x: 0x1B, y: 0x1B6A))
        var other = uid
        other[0] ^= 0xFF
        XCTAssertNotEqual(activate, try Libre2Crypto.activateParameters(uid: other), "the code depends on the sensor")
        XCTAssertThrowsError(try Libre2Crypto.activateParameters(uid: [1, 2, 3]))
    }

    func testStateFromHeaderIgnoresUnsetBody() throws {
        var plain = LibreSimulator.framPlaintext(ageMinutes: 0, state: .notActivated) { _ in 0 }
        plain[100] ^= 0xFF  // a never-started sensor's body may not have a valid checksum
        XCTAssertThrowsError(try LibreFRAM(decrypted: plain))
        XCTAssertEqual(try LibreFRAM.state(decrypted: plain), .notActivated)
        plain[4] ^= 0x01
        XCTAssertThrowsError(try LibreFRAM.state(decrypted: plain), "header checksum still checked")
    }

    func testCryptoRejectsBadInput() {
        XCTAssertThrowsError(try Libre2Crypto.enableStreamingParameters(uid: [1, 2, 3], patchInfo: LibreFixtures.patchInfo))
        XCTAssertThrowsError(try Libre2Crypto.enableStreamingParameters(uid: LibreFixtures.uid, patchInfo: [1]))
        XCTAssertThrowsError(try Libre2Crypto.decryptBLE(uid: LibreFixtures.uid, packet: [UInt8](repeating: 0, count: 20)))
    }

    // MARK: FRAM

    func testFRAMRoundTripAndParse() throws {
        let plain = LibreFixtures.plainFRAM(age: 1234)
        let encrypted = try Libre2Crypto.decryptFRAM(uid: LibreFixtures.uid, patchInfo: LibreFixtures.patchInfo, data: plain)
        XCTAssertNotEqual(encrypted, plain)
        let decrypted = try Libre2Crypto.decryptFRAM(uid: LibreFixtures.uid, patchInfo: LibreFixtures.patchInfo, data: encrypted)
        XCTAssertEqual(decrypted, plain)

        let fram = try LibreFRAM(decrypted: decrypted)
        XCTAssertEqual(fram.state, .active)
        XCTAssertEqual(fram.ageMinutes, 1234)
        XCTAssertEqual(fram.maxLifeMinutes, 21_600)
        XCTAssertEqual(fram.trend.count, 16)
        XCTAssertEqual(fram.trend.first?.minuteIndex, 1234)
        XCTAssertEqual(fram.trend.first?.raw, 1000)
        XCTAssertEqual(fram.trend.last?.minuteIndex, 1219)
        XCTAssertEqual(fram.trend.last?.raw, 1015)
        XCTAssertEqual(fram.trend.first?.rawTemperature, 6000)

        // Last history minute: (1234 - 3) / 15 * 15 = 1230.
        XCTAssertEqual(fram.history.first?.minuteIndex, 1230)
        XCTAssertEqual(fram.history.first?.raw, 2000)
        XCTAssertEqual(fram.history[1].minuteIndex, 1215)
        XCTAssertEqual(fram.history.count, 32)
    }

    func testFRAMWithWrongKeyFailsCRC() throws {
        let plain = LibreFixtures.plainFRAM(age: 500)
        let encrypted = try Libre2Crypto.decryptFRAM(uid: LibreFixtures.uid, patchInfo: LibreFixtures.patchInfo, data: plain)
        var otherUID = LibreFixtures.uid
        otherUID[0] ^= 0x01
        let wrong = try Libre2Crypto.decryptFRAM(uid: otherUID, patchInfo: LibreFixtures.patchInfo, data: encrypted)
        XCTAssertThrowsError(try LibreFRAM(decrypted: wrong))
    }

    func testFRAMEarlyAgeDropsNegativeMinutes() throws {
        let fram = try LibreFRAM(decrypted: LibreFixtures.plainFRAM(age: 20))
        XCTAssertTrue(fram.trend.allSatisfy { $0.minuteIndex >= 0 })
        XCTAssertEqual(fram.history.map(\.minuteIndex), [15, 0])
    }

    // MARK: BLE

    func testBLERoundTripAndParse() throws {
        let plain = LibreFixtures.plainBLE(age: 2000)
        let packet = try Libre2Crypto.encryptBLE(uid: LibreFixtures.uid, plaintext: plain, seed: (0x12, 0x34))
        XCTAssertEqual(packet.count, 46)

        let decrypted = try Libre2Crypto.decryptBLE(uid: LibreFixtures.uid, packet: packet)
        XCTAssertEqual(decrypted, plain)

        let parsed = try LibreBLEPacket(decrypted: decrypted)
        XCTAssertEqual(parsed.ageMinutes, 2000)
        XCTAssertEqual(parsed.trend.map(\.minuteIndex), [2000, 1998, 1996, 1994, 1993, 1988, 1985])
        XCTAssertEqual(parsed.trend.map(\.raw), [1500, 1501, 1502, 1503, 1504, 1505, 1506])
        // (2000 - 2) / 15 * 15 = 1995
        XCTAssertEqual(parsed.history.map(\.minuteIndex), [1995, 1980, 1965])
        XCTAssertEqual(parsed.latest?.rawTemperature, 6000)
    }

    func testBLEHistoryLagsTwoMinutes() throws {
        // At age % 15 == 2 the newest history slot is the current quarter hour, not the one before.
        let parsed = try LibreBLEPacket(decrypted: LibreFixtures.plainBLE(age: 1802))
        XCTAssertEqual(parsed.history.map(\.minuteIndex), [1800, 1785, 1770])
        let earlier = try LibreBLEPacket(decrypted: LibreFixtures.plainBLE(age: 1801))
        XCTAssertEqual(earlier.history.map(\.minuteIndex), [1785, 1770, 1755])
    }

    func testBLETamperedOrForeignPacketIsRejected() throws {
        let packet = try Libre2Crypto.encryptBLE(uid: LibreFixtures.uid, plaintext: LibreFixtures.plainBLE(age: 900), seed: (1, 2))
        var tampered = packet
        tampered[10] ^= 0x40
        XCTAssertThrowsError(try Libre2Crypto.decryptBLE(uid: LibreFixtures.uid, packet: tampered))

        var otherUID = LibreFixtures.uid
        otherUID[2] ^= 0x10
        XCTAssertThrowsError(try Libre2Crypto.decryptBLE(uid: otherUID, packet: packet))
    }

    // MARK: Sensor record

    func testSensorRecordTimelineAndUnlockCounter() throws {
        let now = Date(timeIntervalSince1970: 1_767_614_400)
        var record = LibreSensorRecord(uid: LibreFixtures.uid, patchInfo: LibreFixtures.patchInfo,
                                       ageMinutes: 600, maxLifeMinutes: 0, now: now)
        XCTAssertEqual(record.type, .libre2PlusEU)
        XCTAssertEqual(record.activatedAt, now.addingTimeInterval(-600 * 60))
        XCTAssertEqual(record.maxLifeMinutes, 15 * 1440)
        XCTAssertEqual(record.ageMinutes(at: now), 600)
        XCTAssertEqual(record.warmUpEndsAt, record.activatedAt.addingTimeInterval(3600))

        let p1 = try record.nextUnlockPayload()
        let p2 = try record.nextUnlockPayload()
        XCTAssertEqual(record.unlockCount, 2)
        XCTAssertNotEqual(p1, p2)
    }

    func testSensorRecordConvertsAndFiltersReadings() {
        let now = Date(timeIntervalSince1970: 1_767_614_400)
        var record = LibreSensorRecord(uid: LibreFixtures.uid, patchInfo: LibreFixtures.patchInfo,
                                       ageMinutes: 100, maxLifeMinutes: 0, now: now)
        let raws = [
            LibreRawReading(minuteIndex: 100, raw: 1020, rawTemperature: 0, temperatureAdjustment: 0, hasError: false, isHistory: false),
            LibreRawReading(minuteIndex: 99, raw: 1020, rawTemperature: 0, temperatureAdjustment: 0, hasError: true, isHistory: false),
            LibreRawReading(minuteIndex: 30, raw: 1020, rawTemperature: 0, temperatureAdjustment: 0, hasError: false, isHistory: false),
            LibreRawReading(minuteIndex: 90, raw: 1700, rawTemperature: 0, temperatureAdjustment: 0, hasError: false, isHistory: true),
        ]
        let readings = record.glucoseReadings(from: raws, liveSource: .bluetooth)
        XCTAssertEqual(readings.map(\.minuteIndex), [100, 90], "error and warm-up values are dropped")
        XCTAssertEqual(readings[0].mgdL, 120, "1020 / 8.5 = 120")
        XCTAssertEqual(readings[0].source, .bluetooth)
        XCTAssertEqual(readings[1].source, .backfill)
        XCTAssertEqual(readings[0].raw, 1020)
        XCTAssertEqual(readings[0].timestamp, record.timestamp(forMinute: 100))

        record.addCalibration(referenceMgdL: 130, raw: 1020, date: now)
        XCTAssertEqual(record.glucoseReadings(from: [raws[0]], liveSource: .bluetooth).first?.mgdL, 130)
    }
}
