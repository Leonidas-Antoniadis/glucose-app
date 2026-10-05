import XCTest
import GlucoseCore
@testable import LibreProtocol

/// Real-world situations, simulated end to end with encrypted packets and FRAM:
/// re-pairing, re-scanning while connected, and the phone being out of range.
final class SensorScenarioTests: XCTestCase {
    private let uid = LibreSimulator.demoUID
    private let patch = LibreSimulator.demoPatchInfo
    private let pairedAt = Date(timeIntervalSince1970: 1_767_614_400)
    /// A smooth curve in raw units (about 100-160 mg/dL).
    private let raw: (Int) -> Int = { Int((130 + 30 * sin(Double($0) / 60)) * 8.5) }

    private func record(age: Int) -> LibreSensorRecord {
        LibreSensorRecord(uid: uid, patchInfo: patch, ageMinutes: age, maxLifeMinutes: 0, now: pairedAt)
    }

    /// Readings from the Bluetooth packet the sensor sends at `age`.
    private func bleReadings(_ record: LibreSensorRecord, age: Int) throws -> [GlucoseReading] {
        let packet = try LibreSimulator.blePacket(uid: uid, ageMinutes: age, raw: raw)
        let parsed = try LibreBLEPacket(decrypted: Libre2Crypto.decryptBLE(uid: uid, packet: packet))
        return record.glucoseReadings(from: parsed.history + parsed.trend, liveSource: .bluetooth)
    }

    /// Readings from an NFC scan at `age`.
    private func nfcReadings(_ record: LibreSensorRecord, age: Int) throws -> [GlucoseReading] {
        let fram = try LibreFRAM(decrypted: Libre2Crypto.decryptFRAM(
            uid: uid, patchInfo: patch, data: LibreSimulator.fram(uid: uid, patchInfo: patch, ageMinutes: age, raw: raw)))
        return record.glucoseReadings(from: fram.history + fram.trend, liveSource: .nfc)
    }

    // MARK: Re-pairing

    func testRePairingTheSameSensorKeepsCalibration() {
        var first = record(age: 2000)
        first.addCalibration(referenceMgdL: 140, raw: 1100, date: pairedAt)
        _ = try? first.nextUnlockPayload()
        first.peripheralIdentifier = UUID()

        let again = LibreSensorRecord.paired(uid: uid, patchInfo: patch, ageMinutes: 2300, maxLifeMinutes: 0,
                                             now: pairedAt.addingTimeInterval(300 * 60), previous: first)
        XCTAssertEqual(again.calibrationPoints, first.calibrationPoints)
        XCTAssertTrue(again.calibration.isCalibrated)
        XCTAssertEqual(again.unlockCount, 0, "the sensor was re-enabled, so the counter starts over")
        XCTAssertNil(again.peripheralIdentifier, "the Bluetooth link is confirmed again from the first packet")
        XCTAssertEqual(again.activatedAt, first.activatedAt, "same sensor, same start time")
    }

    func testPairingADifferentSensorStartsFresh() {
        var first = record(age: 2000)
        first.addCalibration(referenceMgdL: 140, raw: 1100, date: pairedAt)
        var otherUID = uid
        otherUID[0] ^= 0xFF
        let other = LibreSensorRecord.paired(uid: otherUID, patchInfo: patch, ageMinutes: 100, maxLifeMinutes: 0,
                                             now: pairedAt, previous: first)
        XCTAssertFalse(other.calibration.isCalibrated)
        XCTAssertTrue(other.calibrationPoints.isEmpty)
    }

    // MARK: Scanning while connected

    func testRescanningWhileConnectedAddsNoDuplicates() throws {
        let sensor = record(age: 3000)
        var stored: [GlucoseReading] = []
        for age in 2990...3000 {
            stored = ReadingPipeline.merge(stored, with: try bleReadings(sensor, age: age))
        }
        let countBefore = Set(stored.map(\.minuteIndex)).count
        // An NFC scan of the same sensor at the same moment.
        let merged = ReadingPipeline.merge(stored, with: try nfcReadings(sensor, age: 3000))
        XCTAssertEqual(merged.count, Set(merged.map(\.id)).count, "each sensor minute stored once")
        XCTAssertGreaterThan(merged.count, countBefore, "NFC adds older history")
        // Overlapping minutes keep the live Bluetooth value.
        let overlap = merged.filter { $0.minuteIndex >= 2990 && $0.minuteIndex <= 3000 }
        XCTAssertTrue(overlap.allSatisfy { $0.source == .bluetooth })
    }

    // MARK: Phone out of range

    func testPhoneAwayLeavesAGapThatAnNFCScanFills() throws {
        let sensor = record(age: 1000)
        var stored: [GlucoseReading] = []
        // Connected for 30 minutes, away for 2 hours, back at age 1150.
        for age in 970...1000 {
            stored = ReadingPipeline.merge(stored, with: try bleReadings(sensor, age: age))
        }
        stored = ReadingPipeline.merge(stored, with: try bleReadings(sensor, age: 1150))
        let backAt = sensor.timestamp(forMinute: 1150)

        let gap = try XCTUnwrap(ReadingPipeline.recentGap(in: stored, now: backAt, lookbackHours: 8))
        XCTAssertEqual(gap.start, sensor.timestamp(forMinute: 1000), "the gap starts at the last reading before leaving")
        XCTAssertLessThanOrEqual(gap.end, backAt)
        XCTAssertGreaterThan(gap.duration, 60 * 60)

        // One Bluetooth packet only reaches back ~45 minutes; the NFC scan's 8-hour history closes the gap.
        stored = ReadingPipeline.merge(stored, with: try nfcReadings(sensor, age: 1150))
        XCTAssertNil(ReadingPipeline.recentGap(in: stored, now: backAt, lookbackHours: 8))
    }

    func testDataStoppingCountsAsAGap() throws {
        let sensor = record(age: 500)
        let stored = try bleReadings(sensor, age: 500)
        let later = sensor.timestamp(forMinute: 540)
        let gap = try XCTUnwrap(ReadingPipeline.recentGap(in: stored, now: later))
        XCTAssertEqual(gap.end, later, "no data since the last reading")
        XCTAssertNil(ReadingPipeline.recentGap(in: stored, now: sensor.timestamp(forMinute: 505)))
    }

    // MARK: Other sensor

    func testPacketsFromAnotherSensorAreRejected() throws {
        var otherUID = uid
        otherUID[3] ^= 0x42
        let foreign = try LibreSimulator.blePacket(uid: otherUID, ageMinutes: 800, raw: raw)
        XCTAssertThrowsError(try Libre2Crypto.decryptBLE(uid: uid, packet: foreign))
    }
}
