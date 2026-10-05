import XCTest
@testable import GlucoseCore

final class TrendAlertTests: XCTestCase {
    private func engine(rules: [AlertRule] = [], trend: [TrendAlert]) throws -> AlertEngine {
        AlertEngine(ruleSet: try AlertRuleSet(rules: rules, trendAlerts: trend), calendar: TestSupport.utc)
    }

    private func run(_ engine: inout AlertEngine, _ values: [Double]) -> [[String]] {
        values.enumerated().map { minute, value in
            engine.process(TestSupport.reading(value, minute: minute)).map(\.ruleName)
        }
    }

    private let lowSoon = TrendAlert(name: "Low soon", kind: .predictiveLow(thresholdMgdL: 70, minutesAhead: 20), sound: .silent)

    func testPredictiveLowFiresOncePerEpisode() throws {
        var e = try engine(trend: [lowSoon])
        // Falling 2 mg/dL per minute from 120: projection 20 min ahead drops below 70 at about 106.
        let values = (0..<12).map { 120 - Double($0) * 2 }
        let fired = run(&e, values)
        let firstFire = fired.firstIndex { !$0.isEmpty }
        XCTAssertNotNil(firstFire)
        XCTAssertEqual(fired.flatMap { $0 }.count, 1, "fires once, not every minute")
    }

    func testPredictiveLowNeedsEnoughData() throws {
        var e = try engine(trend: [lowSoon])
        XCTAssertEqual(run(&e, [120, 100]), [[], []], "two points are not a trend")
    }

    func testPredictiveLowIsSuppressedWhileAThresholdLowIsActive() throws {
        let low = AlertRule(name: "L80", direction: .low, thresholdMgdL: 80, sound: .silent, repeatIntervalMinutes: nil)
        var e = try engine(rules: [low], trend: [lowSoon])
        // Already below 80 and falling: only the threshold rule speaks.
        let fired = run(&e, [79, 77, 75, 73, 71])
        XCTAssertEqual(fired.flatMap { $0 }, ["L80"])
    }

    func testPredictiveLowRearmsAfterRecovery() throws {
        var e = try engine(trend: [lowSoon])
        let falling = (0..<8).map { 120 - Double($0) * 2 }       // fires
        let flat = Array(repeating: 110.0, count: 20)               // clears
        let fallingAgain = (0..<16).map { 110 - Double($0) * 2 }   // fires again once the window is all falling
        let fired = run(&e, falling + flat + fallingAgain).flatMap { $0 }
        XCTAssertEqual(fired, ["Low soon", "Low soon"])
    }

    func testRateAlerts() throws {
        let falling = TrendAlert(name: "Falling", kind: .fallingFast(mgdLPerMinute: 2), sound: .silent)
        let rising = TrendAlert(name: "Rising", kind: .risingFast(mgdLPerMinute: 2), sound: .silent)
        var e = try engine(trend: [falling, rising])
        let fired = run(&e, (0..<6).map { 200 - Double($0) * 3 })
        XCTAssertEqual(fired.flatMap { $0 }, ["Falling"])

        var e2 = try engine(trend: [falling, rising])
        let fired2 = run(&e2, (0..<6).map { 100 + Double($0) * 3 })
        XCTAssertEqual(fired2.flatMap { $0 }, ["Rising"])
    }

    func testSlowChangeDoesNotTriggerRateAlerts() throws {
        let falling = TrendAlert(name: "Falling", kind: .fallingFast(mgdLPerMinute: 2), sound: .silent)
        var e = try engine(trend: [falling])
        XCTAssertTrue(run(&e, (0..<10).map { 150 - Double($0) }).flatMap { $0 }.isEmpty)
    }

    func testAcknowledgeSnoozesTrendAlert() throws {
        var e = try engine(trend: [lowSoon])
        e.acknowledge(ruleID: lowSoon.id, at: TestSupport.noon)
        let fired = run(&e, (0..<10).map { 120 - Double($0) * 2 })
        XCTAssertTrue(fired.flatMap { $0 }.isEmpty, "snoozed for 30 minutes")
    }

    func testDisabledTrendAlertIsIgnored() throws {
        var disabled = lowSoon
        disabled.isEnabled = false
        var e = try engine(trend: [disabled])
        XCTAssertTrue(run(&e, (0..<10).map { 120 - Double($0) * 3 }).flatMap { $0 }.isEmpty)
    }

    func testOldSettingsWithoutTrendAlertsStillDecode() throws {
        let json = #"{"rules":[]}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AlertRuleSet.self, from: json)
        XCTAssertEqual(decoded.trendAlerts.count, TrendAlert.defaults().count)
    }

    func testUrgentLowRules() {
        XCTAssertEqual(AlertRuleSet.basic().urgentLowRules.map(\.thresholdMgdL), [60])
    }
}
