import XCTest
import GlucoseCore
@testable import LibreProtocol

/// How a sensor's calibration changes when fingersticks are added, deleted or re-paired.
final class CalibrationLifecycleTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_767_614_400)

    private func record(ageMinutes: Int = 2000) -> LibreSensorRecord {
        LibreSensorRecord(uid: LibreFixtures.uid, patchInfo: LibreFixtures.patchInfo, ageMinutes: ageMinutes,
                          maxLifeMinutes: 0, now: now)
    }

    func testCalibrationIsRefusedDuringWarmUp() {
        var warming = record(ageMinutes: 30)
        XCTAssertEqual(warming.addCalibration(referenceMgdL: 110, raw: 600, date: now), .warmingUp)
        XCTAssertFalse(warming.calibration.isCalibrated)
    }

    func testDeletedCalibrationFingerstickIsUndone() {
        var sensor = record()
        // 45 typed instead of 145: far from the sensor's 145, so it needs a second fingerstick first.
        guard case .needsConfirmation = sensor.addCalibration(referenceMgdL: 45, raw: 1232, date: now) else {
            return XCTFail("a fingerstick 100 mg/dL off waits for confirmation")
        }
        XCTAssertFalse(sensor.calibration.isCalibrated)

        guard case .applied(let id) = sensor.addCalibration(referenceMgdL: 150, raw: 1232, date: now) else {
            return XCTFail("a plausible fingerstick is used")
        }
        XCTAssertTrue(sensor.calibration.isCalibrated)
        XCTAssertTrue(sensor.removeCalibration(id: id))
        XCTAssertFalse(sensor.calibration.isCalibrated)
        XCTAssertFalse(sensor.removeCalibration(id: id), "already gone")
    }

    func testAnOutlierIsUsedOnceASecondFingerstickAgrees() {
        var sensor = record()
        guard case .needsConfirmation(let shown) = sensor.addCalibration(referenceMgdL: 60, raw: 1020, date: now) else {
            return XCTFail("60 against a sensor showing 120 waits for confirmation")
        }
        XCTAssertEqual(shown, 120, accuracy: 0.001)
        let second = sensor.addCalibration(referenceMgdL: 62, raw: 1020, date: now.addingTimeInterval(5 * 60))
        guard case .applied = second else { return XCTFail("two agreeing fingersticks are believed") }
        XCTAssertEqual(sensor.calibration.mgdL(fromRaw: 1020), 62, accuracy: 0.5)
    }

    func testBackdatedFingerstickDoesNotDropLaterOnes() {
        var sensor = record()
        sensor.addCalibration(referenceMgdL: 130, raw: 1020, date: now)
        sensor.addCalibration(referenceMgdL: 128, raw: 1010, date: now.addingTimeInterval(-2 * 60))
        XCTAssertEqual(sensor.calibration.pointCount, 2)
    }

    func testRePairingKeepsCalibrationAfterFourDays() {
        var first = record()
        sensorCalibrate(&first, reference: 105, raw: 1100)   // offset about -25
        let calibration = first.calibration
        let again = LibreSensorRecord.paired(uid: first.uid, patchInfo: first.patchInfo, ageMinutes: 2000 + 120 * 60,
                                             maxLifeMinutes: 0, now: now.addingTimeInterval(120 * 3600), previous: first)
        XCTAssertEqual(again.calibration, calibration, "re-pairing 120 hours later keeps slope and offset")
    }

    private func sensorCalibrate(_ sensor: inout LibreSensorRecord, reference: Double, raw: Double) {
        guard case .applied = sensor.addCalibration(referenceMgdL: reference, raw: raw, date: now) else {
            return XCTFail("calibration should apply")
        }
    }
}
