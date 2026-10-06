import XCTest
@testable import GlucoseCore

/// When the phone clock jumps, the sensor's start time is re-anchored and its readings re-dated.
final class TimelineShiftTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("retime-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testRetimedSortsNewReadingsAfterOldOnes() {
        // Readings dated by a clock that was 45 minutes fast, then a new reading after the correction.
        let fastStart = TestSupport.noon
        let correctedStart = fastStart.addingTimeInterval(-45 * 60)
        let old = (100..<110).map { TestSupport.reading(120, minute: $0, start: fastStart) }
        let new = TestSupport.reading(70, minute: 110, start: correctedStart)
        XCTAssertLessThan(new.timestamp, old.last!.timestamp, "without re-dating the new reading sorts first")

        let other = GlucoseReading(sensorSerial: "OTHER", minuteIndex: 5, timestamp: fastStart, mgdL: 99, source: .bluetooth)
        let retimed = ReadingPipeline.retimed(old + [other], sensorSerial: "TEST", activatedAt: correctedStart)
        let merged = ReadingPipeline.merge(retimed, with: [new])
        XCTAssertEqual(merged.last?.minuteIndex, 110)
        XCTAssertEqual(merged.last?.mgdL, 70)
        XCTAssertEqual(merged.first { $0.sensorSerial == "OTHER" }?.timestamp, fastStart, "other sensors keep their times")
        XCTAssertEqual(retimed.first { $0.minuteIndex == 100 }?.timestamp, correctedStart.addingTimeInterval(100 * 60))
    }

    func testEngineShiftKeepsRepeatsRunning() throws {
        let rule = AlertRule(name: "Low", direction: .low, thresholdMgdL: 70, sound: .silent,
                             repeatIntervalMinutes: 5, maxRepeats: nil, snoozeMinutes: 30, schedule: .always,
                             confirmationMinutes: 0, rearmMarginMgdL: 5)
        var engine = AlertEngine(ruleSet: try AlertRuleSet(rules: [rule], trendAlerts: []), calendar: TestSupport.utc)
        let fastStart = TestSupport.noon
        XCTAssertEqual(engine.process(TestSupport.reading(65, minute: 0, start: fastStart)).count, 1)

        // The clock is corrected 45 minutes back; readings from now on are dated by the new clock.
        let shift: TimeInterval = -45 * 60
        engine.shiftTimeline(by: shift)
        let correctedStart = fastStart.addingTimeInterval(shift)
        XCTAssertTrue(engine.process(TestSupport.reading(64, minute: 3, start: correctedStart)).isEmpty)
        let reminder = engine.process(TestSupport.reading(63, minute: 5, start: correctedStart))
        XCTAssertEqual(reminder.map(\.kind), [.reminder(count: 1)], "the 5-minute repeat still comes after 5 minutes")
    }

    func testArchiveRetimeRewritesOneSensor() throws {
        let archive = try ReadingArchive(directory: directory)
        let fastStart = TestSupport.noon
        let readings = (0..<120).map { TestSupport.reading(100, minute: $0 * 15, start: fastStart) }  // 30 hours
        let other = GlucoseReading(sensorSerial: "OTHER", minuteIndex: 1, timestamp: fastStart, mgdL: 99, source: .bluetooth)
        try archive.append(readings + [other])

        let correctedStart = fastStart.addingTimeInterval(-45 * 60)
        try archive.retime(sensorSerial: "TEST", activatedAt: correctedStart, through: fastStart.addingTimeInterval(2 * 86_400))
        let loaded = try archive.load(from: fastStart.addingTimeInterval(-86_400), to: fastStart.addingTimeInterval(3 * 86_400))
        let test = loaded.filter { $0.sensorSerial == "TEST" }
        XCTAssertEqual(test.count, 120, "nothing lost or doubled")
        XCTAssertTrue(test.allSatisfy { $0.timestamp == correctedStart.addingTimeInterval(Double($0.minuteIndex) * 60) })
        XCTAssertEqual(loaded.first { $0.sensorSerial == "OTHER" }?.timestamp, fastStart)
    }
}
