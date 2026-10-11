import XCTest
import Foundation
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

    func testFirstDayCalibrationsCountLess() {
        // A first-day calibration 60 mg/dL above the signal, then one that matches it.
        let points = [point(160, raw: 850, hoursAgo: 30), point(100, raw: 850)]
        let plain = Calibration.fit(points, now: now)
        let damped = Calibration.fit(points, now: now, firstDayEnds: now.addingTimeInterval(-29 * 3600))
        let w = pow(0.5, 30.0 / 24)
        XCTAssertEqual(plain.intercept, 60 * w / (w + 1), accuracy: 0.01)
        XCTAssertEqual(damped.intercept, 60 * 0.2 * w / (0.2 * w + 1), accuracy: 0.01)
        XCTAssertLessThan(damped.intercept, plain.intercept / 3)
        // Only first-day points: all count less alike, so the fit itself is the same.
        let alone = [point(160, raw: 850, hoursAgo: 2)]
        XCTAssertEqual(Calibration.fit(alone, now: now, firstDayEnds: now).intercept,
                       Calibration.fit(alone, now: now).intercept, accuracy: 0.0001)
    }

    func testCloseValuesDoNotFitSlope() {
        let calibration = Calibration.fit([point(100, raw: 800), point(110, raw: 900)], now: now)
        XCTAssertEqual(calibration.slope, Calibration.defaultSlope)
    }

    func testSlopeIsClamped() {
        let calibration = Calibration.fit([point(60, raw: 1000), point(300, raw: 1100)], now: now)
        XCTAssertEqual(calibration.slope, Calibration.slopeRange.upperBound, accuracy: 1e-9)
    }

    func testContradictingPointsKeepTheDefaultSlope() {
        // A contaminated finger: 170 at raw 680, then the real 120 at raw 1020. The relation is
        // backwards, so no slope is fitted (it used to be clamped flat, showing a raw-425 low as 110).
        let calibration = Calibration.fit([point(170, raw: 680, hoursAgo: 1), point(120, raw: 1020)], now: now)
        XCTAssertEqual(calibration.slope, Calibration.defaultSlope)
        XCTAssertLessThan(calibration.mgdL(fromRaw: 425), 100)
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
