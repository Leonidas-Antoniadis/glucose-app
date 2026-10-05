import XCTest
@testable import GlucoseCore

final class UnitAndReadingTests: XCTestCase {
    func testUnitConversionRoundTrips() {
        XCTAssertEqual(GlucoseUnit.mmolL.fromMgdL(180.16), 10.0, accuracy: 0.001)
        XCTAssertEqual(GlucoseUnit.mmolL.toMgdL(3.9), 70.26, accuracy: 0.01)
        XCTAssertEqual(GlucoseUnit.mgdL.fromMgdL(123), 123)
    }

    func testFormatting() {
        XCTAssertEqual(GlucoseUnit.mgdL.format(mgdL: 99.6), "100")
        XCTAssertEqual(GlucoseUnit.mmolL.format(mgdL: 72), "4.0")
        XCTAssertEqual(GlucoseUnit.mmolL.format(mgdL: 180, includeSymbol: true), "10.0 mmol/L")
    }

    func testMergeDeduplicatesAndPrefersLiveValues() {
        let backfill = TestSupport.reading(100, minute: 1, source: .backfill)
        let live = TestSupport.reading(102, minute: 1, source: .bluetooth)
        let other = TestSupport.reading(105, minute: 2, source: .backfill)

        let merged = ReadingPipeline.merge([backfill, other], with: [live])
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged.first?.mgdL, 102)

        // A later backfill must not overwrite the live value.
        let again = ReadingPipeline.merge(merged, with: [backfill])
        XCTAssertEqual(again.first?.mgdL, 102)
    }

    func testMergeDropsImplausibleValues() {
        let merged = ReadingPipeline.merge([], with: [
            TestSupport.reading(0, minute: 0),
            TestSupport.reading(.nan, minute: 1),
            TestSupport.reading(900, minute: 2),
            TestSupport.reading(110, minute: 3),
        ])
        XCTAssertEqual(merged.map(\.mgdL), [110])
    }

    func testGapDetection() {
        let readings = [0, 1, 2, 6, 7, 10].map { TestSupport.reading(100, minute: $0) }
        XCTAssertEqual(ReadingPipeline.gaps(in: readings, sensorSerial: "TEST"), [3...5, 8...9])
    }

    func testTrendArrows() {
        let falling = (0..<15).map { TestSupport.reading(150 - Double($0) * 3, minute: $0) }
        XCTAssertEqual(Trend.ratePerMinute(falling) ?? 0, -3, accuracy: 0.0001)
        XCTAssertEqual(Trend.arrow(forRate: Trend.ratePerMinute(falling)), .fallingQuickly)

        let flat = (0..<15).map { TestSupport.reading(110, minute: $0) }
        XCTAssertEqual(Trend.arrow(forRate: Trend.ratePerMinute(flat)), .stable)

        XCTAssertEqual(Trend.arrow(forRate: 1.5), .rising)
        XCTAssertEqual(Trend.arrow(forRate: -1.5), .falling)
        XCTAssertEqual(Trend.arrow(forRate: nil), .unknown)
        XCTAssertNil(Trend.ratePerMinute([TestSupport.reading(100, minute: 0)]))
    }

    func testProjection() {
        let falling = (0..<15).map { TestSupport.reading(150 - Double($0) * 2, minute: $0) }
        // Last value 122, falling 2/min -> 82 in 20 minutes.
        XCTAssertEqual(Trend.projected(falling, minutesAhead: 20) ?? 0, 82, accuracy: 0.001)
    }

    func testSimulatedSensorIsDeterministicAndPlausible() {
        let sensor = SimulatedSensor(startedAt: TestSupport.noon)
        let readings = sensor.readings(minutes: 0..<1440)
        XCTAssertEqual(readings, sensor.readings(minutes: 0..<1440))
        XCTAssertTrue(readings.allSatisfy(ReadingPipeline.isPlausible))
        XCTAssertTrue(readings.contains { $0.mgdL < 70 }, "demo data should exercise low alerts")
        XCTAssertTrue(readings.contains { $0.mgdL > 180 }, "demo data should exercise high alerts")
    }
}
