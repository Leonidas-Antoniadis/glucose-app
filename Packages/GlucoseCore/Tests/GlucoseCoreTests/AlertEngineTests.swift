import XCTest
@testable import GlucoseCore

final class AlertEngineTests: XCTestCase {
    private func rule(_ name: String, _ direction: AlertDirection, _ threshold: Double,
                      repeatEvery: Int? = nil, maxRepeats: Int? = nil, confirm: Int = 0,
                      schedule: AlertSchedule = .always) -> AlertRule {
        AlertRule(name: name, direction: direction, thresholdMgdL: threshold, sound: .silent,
                  repeatIntervalMinutes: repeatEvery, maxRepeats: maxRepeats, snoozeMinutes: 30,
                  schedule: schedule, confirmationMinutes: confirm, rearmMarginMgdL: 5)
    }

    private func engine(_ rules: [AlertRule]) throws -> AlertEngine {
        AlertEngine(ruleSet: try AlertRuleSet(rules: rules, trendAlerts: []), calendar: TestSupport.utc)
    }

    /// Feeds values one per minute and returns the names that fired at each minute.
    private func run(_ engine: inout AlertEngine, _ values: [Double]) -> [[String]] {
        values.enumerated().map { minute, value in
            engine.process(TestSupport.reading(value, minute: minute)).map(\.ruleName)
        }
    }

    func testFiresOncePerCrossing() throws {
        var e = try engine([rule("L80", .low, 80)])
        let fired = run(&e, [90, 79, 78, 77])
        XCTAssertEqual(fired, [[], ["L80"], [], []])
    }

    func testOnlyMostSevereRuleSounds() throws {
        var e = try engine([rule("L80", .low, 80), rule("L70", .low, 70), rule("L60", .low, 60)])
        // Fast drop straight past all three.
        let fired = run(&e, [100, 58])
        XCTAssertEqual(fired, [[], ["L60"]])
    }

    func testEscalatesWhenFallingFurther() throws {
        var e = try engine([rule("L80", .low, 80), rule("L70", .low, 70), rule("L60", .low, 60)])
        let fired = run(&e, [100, 78, 75, 68, 59])
        XCTAssertEqual(fired, [[], ["L80"], [], ["L70"], ["L60"]])
    }

    func testRecoveringDoesNotReFireLesserRules() throws {
        var e = try engine([rule("L80", .low, 80), rule("L70", .low, 70)])
        // Drop past both (only L70 sounds), then recover to 75: L80 is still crossed but was covered.
        let fired = run(&e, [100, 65, 75, 78])
        XCTAssertEqual(fired, [[], ["L70"], [], []])
    }

    func testHysteresisRearm() throws {
        var e = try engine([rule("L70", .low, 70)])
        // 72 is not past threshold + margin (75), so no re-arm; 76 re-arms; 69 fires again.
        let fired = run(&e, [69, 72, 69, 76, 69])
        XCTAssertEqual(fired, [["L70"], [], [], [], ["L70"]])
    }

    func testRepeatsUntilMax() throws {
        var e = try engine([rule("L70", .low, 70, repeatEvery: 2, maxRepeats: 2)])
        let fired = run(&e, Array(repeating: 65, count: 8))
        // initial at 0, reminders at 2 and 4, then capped.
        XCTAssertEqual(fired.map(\.count), [1, 0, 1, 0, 1, 0, 0, 0])
    }

    func testReminderKindsCount() throws {
        var e = try engine([rule("L70", .low, 70, repeatEvery: 1)])
        let kinds = (0..<3).map { e.process(TestSupport.reading(65, minute: $0)).first?.kind }
        XCTAssertEqual(kinds, [.initial, .reminder(count: 1), .reminder(count: 2)])
    }

    func testAcknowledgeSnoozesThenAlertsAgain() throws {
        let low = rule("L70", .low, 70, repeatEvery: 1)
        var e = try engine([low])
        _ = e.process(TestSupport.reading(65, minute: 0))
        e.acknowledge(ruleID: low.id, at: TestSupport.noon)   // 30 min snooze

        let during = (1..<30).flatMap { e.process(TestSupport.reading(65, minute: $0)) }
        XCTAssertTrue(during.isEmpty)
        let after = e.process(TestSupport.reading(65, minute: 30))
        XCTAssertEqual(after.first?.kind, .afterSnooze)
    }

    func testConfirmationDelayFiltersShortDips() throws {
        var e = try engine([rule("L70", .low, 70, confirm: 3)])
        // Two-minute compression dip: no alert. Then a sustained low alerts after 3 minutes.
        let fired = run(&e, [65, 66, 90, 65, 65, 65, 65])
        XCTAssertEqual(fired, [[], [], [], [], [], [], ["L70"]])
    }

    func testScheduleWindow() throws {
        // Night-only rule (22:00-07:00); TestSupport.noon is 12:00 UTC.
        var e = try engine([rule("Night", .low, 70, schedule: .nightOnly)])
        XCTAssertTrue(e.process(TestSupport.reading(60, minute: 0)).isEmpty)
        // 11 hours later = 23:00, still low and still the same crossing -> fires now.
        XCTAssertEqual(e.process(TestSupport.reading(60, minute: 660)).map(\.ruleName), ["Night"])
    }

    func testLowAndHighAreIndependent() throws {
        var e = try engine([rule("L70", .low, 70), rule("H180", .high, 180)])
        let fired = run(&e, [65, 190])
        XCTAssertEqual(fired, [["L70"], ["H180"]])
    }

    func testDisabledRulesNeverFire() throws {
        var r = rule("L70", .low, 70)
        r.isEnabled = false
        var e = try engine([r])
        XCTAssertEqual(run(&e, [60, 50]), [[], []])
    }

    func testEveryDecisionIsLogged() throws {
        var e = try engine([rule("L80", .low, 80), rule("L70", .low, 70)])
        _ = run(&e, [65, 90])
        XCTAssertTrue(e.log.contains { $0.contains("suppressed L80") })
        XCTAssertTrue(e.log.contains { $0.contains("fired L70") })
        XCTAssertTrue(e.log.contains { $0.contains("re-armed L70") })
    }
}
