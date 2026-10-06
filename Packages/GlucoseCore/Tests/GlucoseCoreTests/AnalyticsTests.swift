import XCTest
@testable import GlucoseCore

final class AnalyticsTests: XCTestCase {
    private let hour = DateInterval(start: TestSupport.noon, duration: 3600)

    func testBasicStatistics() throws {
        let values: [Double] = [100, 120, 140, 160]
        let readings = values.enumerated().map { TestSupport.reading($1, minute: $0) }
        let stats = try XCTUnwrap(GlucoseStatistics(readings: readings, period: hour))

        XCTAssertEqual(stats.count, 4)
        XCTAssertEqual(stats.meanMgdL, 130, accuracy: 0.0001)
        XCTAssertEqual(stats.standardDeviationMgdL, 22.3607, accuracy: 0.001)
        XCTAssertEqual(stats.coefficientOfVariation, 17.2005, accuracy: 0.001)
        XCTAssertEqual(stats.gmiPercent, 3.31 + 0.02392 * 130, accuracy: 0.0001)
        XCTAssertTrue(stats.isCVStable)
    }

    func testRangeBoundaries() throws {
        // One value in each band, with boundary values placed per the consensus definitions.
        let values: [Double] = [53, 54, 69, 70, 180, 181, 250, 251]
        let readings = values.enumerated().map { TestSupport.reading($1, minute: $0) }
        let r = try XCTUnwrap(GlucoseStatistics(readings: readings, period: hour)).ranges

        XCTAssertEqual(r.veryLow, 1.0 / 8)
        XCTAssertEqual(r.low, 2.0 / 8)
        XCTAssertEqual(r.inRange, 2.0 / 8)
        XCTAssertEqual(r.high, 2.0 / 8)
        XCTAssertEqual(r.veryHigh, 1.0 / 8)
        XCTAssertEqual(r.belowRange, 3.0 / 8)
        XCTAssertEqual(r.veryLow + r.low + r.inRange + r.high + r.veryHigh, 1, accuracy: 1e-12)
    }

    func testDataSufficiency() throws {
        let half = (0..<30).map { TestSupport.reading(120, minute: $0) }
        let stats = try XCTUnwrap(GlucoseStatistics(readings: half, period: hour))
        XCTAssertEqual(stats.dataSufficiency, 0.5, accuracy: 0.0001)
        XCTAssertFalse(stats.hasSufficientData)
    }

    func testEmptyPeriodReturnsNil() {
        XCTAssertNil(GlucoseStatistics(readings: [], period: hour))
    }

    func testPercentileInterpolation() {
        let sorted: [Double] = [10, 20, 30, 40, 50]
        XCTAssertEqual(AmbulatoryGlucoseProfile.percentile(sorted, 0.5), 30)
        XCTAssertEqual(AmbulatoryGlucoseProfile.percentile(sorted, 0.25), 20)
        XCTAssertEqual(AmbulatoryGlucoseProfile.percentile(sorted, 0.1), 14, accuracy: 0.0001)
        XCTAssertEqual(AmbulatoryGlucoseProfile.percentile([7], 0.95), 7)
    }

    func testAGPBinsByTimeOfDayAcrossDays() {
        // Same clock time (12:00-12:14) on three different days.
        let readings = (0..<3).flatMap { day in
            (0..<15).map { minute in
                TestSupport.reading(100 + Double(day) * 10, minute: day * 1440 + minute)
            }
        }
        let agp = AmbulatoryGlucoseProfile(readings: readings, binMinutes: 15, calendar: TestSupport.utc)
        XCTAssertEqual(agp.bins.count, 1)
        let bin = agp.bins[0]
        XCTAssertEqual(bin.minuteOfDay, 12 * 60)
        XCTAssertEqual(bin.count, 45)
        XCTAssertEqual(bin.median, 110)
        XCTAssertLessThanOrEqual(bin.p5, bin.p25)
        XCTAssertLessThanOrEqual(bin.p75, bin.p95)
    }

    func testBackfilledReadingsCountByTheTimeTheyCover() throws {
        // A night at 60 imported as 32 history values (every 15 minutes), then 16 live hours at 120.
        let night = (0..<32).map { TestSupport.reading(60, minute: $0 * 15, source: .backfill) }
        let day = (480..<1440).map { TestSupport.reading(120, minute: $0) }
        let stats = try XCTUnwrap(GlucoseStatistics(readings: night + day, period: DateInterval(start: TestSupport.noon, duration: 86_400)))
        XCTAssertEqual(stats.ranges.low, 1.0 / 3, accuracy: 0.001, "the night is a third of the day, not 3%")
        XCTAssertEqual(stats.dataSufficiency, 1, accuracy: 0.001)
    }

    func testReadingBeforeAGapCountsOneMinute() {
        let readings = [TestSupport.reading(100, minute: 0), TestSupport.reading(100, minute: 180), TestSupport.reading(100, minute: 181)]
        XCTAssertEqual(ReadingPipeline.timeWeights(readings), [1, 1, 1], "a 3-hour gap is missing data, not coverage")
    }

    func testTrendIgnoresAnotherSensorsReadings() {
        // Two flat sensors 30 mg/dL apart, overlapping in time after a sensor change.
        let old = (0..<15).map { GlucoseReading(sensorSerial: "OLD", minuteIndex: 5000 + $0, timestamp: TestSupport.noon.addingTimeInterval(Double($0) * 60),
                                                mgdL: 100, source: .bluetooth) }
        let new = (8..<16).map { GlucoseReading(sensorSerial: "NEW", minuteIndex: 200 + $0, timestamp: TestSupport.noon.addingTimeInterval(Double($0) * 60 + 30),
                                                mgdL: 130, source: .bluetooth) }
        XCTAssertEqual(Trend.ratePerMinute(old + new) ?? .nan, 0, accuracy: 0.0001)
    }

    func testRecalibratedReadingsShowNoStep() {
        // Flat at 120 (raw 1020, uncalibrated), then a calibration to 90 at the newest reading.
        let readings = (0..<16).map { minute in
            GlucoseReading(sensorSerial: "TEST", minuteIndex: minute, timestamp: TestSupport.noon.addingTimeInterval(Double(minute) * 60),
                           mgdL: 120, source: .bluetooth, raw: 1020)
        }
        let calibration = Calibration.fit([CalibrationPoint(date: TestSupport.noon.addingTimeInterval(15 * 60), referenceMgdL: 90, raw: 1020)],
                                          now: TestSupport.noon.addingTimeInterval(15 * 60))
        // Without recomputing, the old values next to a new 90 make a falling trend.
        let stepped = Array(readings.dropLast()) + [readings.last!.withValue(90)]
        XCTAssertLessThan(Trend.ratePerMinute(stepped) ?? 0, -0.5)
        let fixed = ReadingPipeline.recalibrated(readings, sensorSerial: "TEST", since: TestSupport.noon, calibration: calibration)
        XCTAssertEqual(fixed.map(\.mgdL), Array(repeating: 90, count: 16))
        XCTAssertEqual(Trend.ratePerMinute(fixed) ?? .nan, 0, accuracy: 0.0001)
    }

    func testConsensusTargets() throws {
        let good = (0..<100).map { TestSupport.reading($0 < 2 ? 65 : 120, minute: $0) }
        let stats = try XCTUnwrap(GlucoseStatistics(readings: good, period: DateInterval(start: TestSupport.noon, duration: 6000)))
        XCTAssertTrue(stats.ranges.meetsConsensusTargets)
    }
}
