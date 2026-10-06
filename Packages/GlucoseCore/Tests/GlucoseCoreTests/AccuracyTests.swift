import XCTest
@testable import GlucoseCore

final class AccuracyTests: XCTestCase {
    private let noon = TestSupport.noon

    private func pair(_ meter: Double, _ app: Double, libreLink: Double? = nil, day: Int? = 5,
                      rate: Double? = 0, minute: Int = 0) -> AccuracyReport.Pair {
        AccuracyReport.Pair(date: noon.addingTimeInterval(Double(minute) * 60), referenceMgdL: meter, sensorMgdL: app,
                            libreLinkMgdL: libreLink, sensorSerial: "TEST", sensorDay: day, ratePerMinute: rate)
    }

    func testErrorGridZones() {
        XCTAssertEqual(ParkesErrorGrid.zone(referenceMgdL: 100, sensorMgdL: 100), .a)
        XCTAssertEqual(ParkesErrorGrid.zone(referenceMgdL: 100, sensorMgdL: 135), .b)
        XCTAssertEqual(ParkesErrorGrid.zone(referenceMgdL: 100, sensorMgdL: 180), .c)
        XCTAssertEqual(ParkesErrorGrid.zone(referenceMgdL: 100, sensorMgdL: 400), .d)
        XCTAssertEqual(ParkesErrorGrid.zone(referenceMgdL: 40, sensorMgdL: 300), .e, "a deep low read as high")
        XCTAssertEqual(ParkesErrorGrid.zone(referenceMgdL: 200, sensorMgdL: 120), .b)
        XCTAssertEqual(ParkesErrorGrid.zone(referenceMgdL: 300, sensorMgdL: 60), .c)
        XCTAssertEqual(ParkesErrorGrid.zone(referenceMgdL: 300, sensorMgdL: 50), .d)
        XCTAssertEqual(ParkesErrorGrid.zone(referenceMgdL: 30, sensorMgdL: 45), .a, "left of the lower boundary nothing is too low")
    }

    func testBoundaryValues() {
        let upperA = ParkesErrorGrid.boundaries[0].upper
        XCTAssertEqual(ParkesErrorGrid.value(of: upperA, at: 140) ?? 0, 170, accuracy: 0.001)
        XCTAssertEqual(ParkesErrorGrid.value(of: upperA, at: 85) ?? 0, 110, accuracy: 0.001)
        let lowerA = ParkesErrorGrid.boundaries[0].lower!
        XCTAssertNil(ParkesErrorGrid.value(of: lowerA, at: 40))
        XCTAssertEqual(ParkesErrorGrid.value(of: lowerA, at: 50) ?? 0, 30, accuracy: 0.001, "the top of the vertical step")
        XCTAssertEqual(ParkesErrorGrid.value(of: lowerA, at: 600) ?? 0, 450 + 50 * (150.0 / 165), accuracy: 0.001,
                       "the last segment continues")
    }

    func testSummaryStatistics() {
        let report = AccuracyReport(pairs: [pair(100, 110), pair(100, 95), pair(200, 180), pair(80, 100), pair(150, 150)])
        XCTAssertEqual(report.mard ?? 0, (10 + 5 + 10 + 25 + 0) / 5.0, accuracy: 0.001)
        XCTAssertEqual(report.biasMgdL ?? 0, (10 - 5 - 20 + 20 + 0) / 5.0, accuracy: 0.001)
        XCTAssertEqual(report.within15_15, 0.8, "80 read as 100 is 20 mg/dL off")
        XCTAssertEqual(report.within20_20, 1.0)
        let interval = report.mardInterval!
        XCTAssertLessThan(interval.lowerBound, report.mard!)
        XCTAssertGreaterThan(interval.upperBound, report.mard!)
        XCTAssertGreaterThanOrEqual(interval.lowerBound, 0)
        XCTAssertNil(AccuracyReport(pairs: [pair(100, 110), pair(100, 90)]).mardInterval, "two checks give no range")
        XCTAssertEqual(report.zoneCounts[.a], 5)
    }

    func testIntervalNarrowsWithMoreChecks() {
        let few = AccuracyReport(pairs: (0..<4).map { pair(100, $0.isMultiple(of: 2) ? 110 : 92, minute: $0) })
        let many = AccuracyReport(pairs: (0..<40).map { pair(100, $0.isMultiple(of: 2) ? 110 : 92, minute: $0) })
        let width = { (r: AccuracyReport) in r.mardInterval!.upperBound - r.mardInterval!.lowerBound }
        XCTAssertLessThan(width(many), width(few))
    }

    func testLibreLinkComparisonUsesTheSameChecks() {
        let report = AccuracyReport(pairs: [pair(100, 110, libreLink: 104), pair(200, 190, libreLink: 180), pair(100, 150)])
        let comparison = report.libreLinkComparison!
        XCTAssertEqual(comparison.count, 2)
        XCTAssertEqual(comparison.libreLink, (4 + 10) / 2.0, accuracy: 0.001)
        XCTAssertEqual(comparison.app, (10 + 5) / 2.0, accuracy: 0.001, "the 150 without a LibreLink value isn't counted")
        XCTAssertNil(AccuracyReport(pairs: [pair(100, 110)]).libreLinkComparison)
    }

    func testBreakdowns() {
        let report = AccuracyReport(pairs: [
            pair(60, 70, day: 1, rate: 0.2),
            pair(120, 132, day: 1, rate: 1.5),
            pair(120, 126, day: 3, rate: -0.5),
            pair(250, 225, day: 3, rate: 2.5),
        ])
        XCTAssertEqual(report.summary(.belowRange)?.count, 1)
        XCTAssertEqual(report.summary(.inRange)?.count, 2)
        XCTAssertEqual(report.summary(.aboveRange)?.count, 1)
        XCTAssertEqual(report.summary(.firstDay)?.count, 2)
        XCTAssertEqual(report.summary(.firstDay)?.mard ?? 0, (100.0 / 6 + 10) / 2, accuracy: 0.001)
        XCTAssertEqual(report.summary(.steady)?.count, 2)
        XCTAssertEqual(report.summary(.moving)?.count, 1)
        XCTAssertEqual(report.summary(.fast)?.count, 1)
        XCTAssertTrue(report.summary(.fast)!.isTooFew)
        XCTAssertEqual(report.dailySummaries(sensorSerial: "TEST").keys.sorted(), [1, 3])
    }

    func testPairsCarrySensorDayAndRate() {
        // A steady rise of 2 mg/dL per minute on sensor day 2 (minute 1440 onwards).
        let readings = (0..<20).map { TestSupport.reading(100 + Double($0) * 2, minute: 1440 + $0) }
        let stick = FingerstickEntry(date: readings[15].timestamp.addingTimeInterval(20), mgdL: 125, usedForCalibration: false,
                                     libreLinkMgdL: 128)
        let report = AccuracyReport(fingersticks: [stick], readings: readings)
        let pair = report.pairs.first!
        XCTAssertEqual(pair.sensorMgdL, 130)
        XCTAssertEqual(pair.sensorDay, 2)
        XCTAssertEqual(pair.ratePerMinute ?? 0, 2, accuracy: 0.001)
        XCTAssertEqual(pair.libreLinkMgdL, 128)
    }

    func testCSVHasOneLinePerCheck() {
        let csv = AccuracyReport(pairs: [pair(100, 110, libreLink: 104), pair(200, 190)]).csv()
        let lines = csv.split(separator: "\n")
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[1].hasSuffix(",100,110,104,10,10.0,A,5,0.00"), String(lines[1]))
    }
}
