import XCTest
@testable import GlucoseCore

final class CalibrationTests: XCTestCase {
    private let now = TestSupport.noon

    private func point(_ reference: Double, raw: Double, hoursAgo: Double = 0) -> CalibrationPoint {
        CalibrationPoint(date: now.addingTimeInterval(-hoursAgo * 3600), referenceMgdL: reference, raw: raw)
    }

    func testUncalibratedUsesDefaultSlope() {
        let calibration = Calibration.fit([], now: now)
        XCTAssertFalse(calibration.isCalibrated)
        XCTAssertEqual(calibration.mgdL(fromRaw: 850), 100, accuracy: 0.0001)
        XCTAssertTrue(calibration.needsCalibration(now: now))
    }

    func testSinglePointShiftsOffsetOnly() {
        let calibration = Calibration.fit([point(110, raw: 850)], now: now)
        XCTAssertEqual(calibration.slope, Calibration.defaultSlope)
        XCTAssertEqual(calibration.mgdL(fromRaw: 850), 110, accuracy: 0.0001)
        XCTAssertEqual(calibration.mgdL(fromRaw: 1700), 210, accuracy: 0.0001)
        XCTAssertFalse(calibration.needsCalibration(now: now))
    }

    func testTwoSpreadPointsFitSlope() {
        // True relation: mgdL = raw / 10.
        let calibration = Calibration.fit([point(80, raw: 800, hoursAgo: 1), point(200, raw: 2000)], now: now)
        XCTAssertEqual(calibration.slope, 0.1, accuracy: 0.0001)
        XCTAssertEqual(calibration.intercept, 0, accuracy: 0.001)
        XCTAssertEqual(calibration.pointCount, 2)
    }

    func testCloseValuesDoNotFitSlope() {
        let calibration = Calibration.fit([point(100, raw: 800), point(110, raw: 900)], now: now)
        XCTAssertEqual(calibration.slope, Calibration.defaultSlope)
    }

    func testSlopeIsClamped() {
        let calibration = Calibration.fit([point(60, raw: 1000), point(300, raw: 1100)], now: now)
        XCTAssertEqual(calibration.slope, Calibration.slopeRange.upperBound, accuracy: 1e-9)
    }

    func testOldPointsAreIgnored() {
        let calibration = Calibration.fit([point(200, raw: 850, hoursAgo: 120)], now: now)
        XCTAssertFalse(calibration.isCalibrated)
    }

    func testRecentPointsWeighMore() {
        let calibration = Calibration.fit([point(140, raw: 850, hoursAgo: 72), point(100, raw: 850)], now: now)
        // Weighted mean leans heavily to the recent 100.
        XCTAssertLessThan(calibration.mgdL(fromRaw: 850), 106)
        XCTAssertGreaterThan(calibration.mgdL(fromRaw: 850), 100)
    }

    func testAccuracyReport() {
        let readings = [
            TestSupport.reading(100, minute: 0),
            TestSupport.reading(150, minute: 30),
            TestSupport.reading(80, minute: 60),
        ]
        let sticks = [
            FingerstickEntry(date: now, mgdL: 110, usedForCalibration: false),                          // 9.1%, within 15 mg/dL? ref>=100 -> 9.1% ok
            FingerstickEntry(date: now.addingTimeInterval(31 * 60), mgdL: 120, usedForCalibration: false), // 25%, outside
            FingerstickEntry(date: now.addingTimeInterval(60 * 60), mgdL: 70, usedForCalibration: true),   // excluded
            FingerstickEntry(date: now.addingTimeInterval(200 * 60), mgdL: 90, usedForCalibration: false), // no reading nearby
        ]
        let report = AccuracyReport(fingersticks: sticks, readings: readings)
        XCTAssertEqual(report.pairs.count, 2)
        XCTAssertEqual(report.mard ?? 0, (10.0 / 110 + 30.0 / 120) / 2 * 100, accuracy: 0.001)
        XCTAssertEqual(report.within15_15, 0.5)

        let lowRange = AccuracyReport.Pair(date: now, referenceMgdL: 70, sensorMgdL: 84)
        XCTAssertTrue(lowRange.isWithin15_15, "below 100 mg/dL the band is +/-15 mg/dL")
    }
}
