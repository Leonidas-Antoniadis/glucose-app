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

    // MARK: Fix plan phase 2

    func testCoveredRuleRemindsAfterTheMoreSevereRuleStops() throws {
        // Night preset style: 70 with a 10-minute confirmation and 5-minute repeats, urgent at 55.
        var e = try engine([rule("Night low", .low, 70, repeatEvery: 5, confirm: 10), rule("Urgent", .low, 55, repeatEvery: 5)])
        // Falls 1.5 mg/dL per minute from 69 to 54, then holds at 56 (urgent no longer crossed).
        let values = (0...10).map { 69 - Double($0) * 1.5 } + Array(repeating: 56, count: 8)
        let fired = run(&e, values)
        XCTAssertEqual(fired[10], ["Urgent"])
        XCTAssertEqual(fired[11..<15].flatMap { $0 }, [])
        XCTAssertEqual(fired[15], ["Night low"], "nobody snoozed, so the covered rule reminds")
    }

    func testNewLowAfterADataGapAlertsAgain() throws {
        var e = try engine([rule("Urgent", .low, 60, repeatEvery: 5, maxRepeats: 3)])
        let first = (0..<16).flatMap { e.process(TestSupport.reading(58, minute: $0)) }
        XCTAssertEqual(first.count, 4, "initial alert and 3 reminders")
        // 100 minutes without data (the recovery and the new fall were never seen), then 56.
        XCTAssertEqual(e.process(TestSupport.reading(56, minute: 115)).map(\.kind), [.initial])
    }

    func testSnoozeOnAnOldAlertDoesNotMuteTheNextLow() throws {
        let urgent = rule("Urgent", .low, 60, repeatEvery: 5)
        var e = try engine([urgent])
        _ = run(&e, [58, 120])   // fired, then recovered and re-armed
        XCTAssertFalse(e.acknowledge(ruleID: urgent.id, at: TestSupport.noon.addingTimeInterval(120)))
        let later = (3..<14).map { e.process(TestSupport.reading(57, minute: $0)).map(\.kind) }
        XCTAssertEqual(later[0], [.initial])
        XCTAssertEqual(later[5], [.reminder(count: 1)], "reminders aren't muted by the old snooze")
    }

    func testSnoozeCoversEverySoundingRuleInThatDirection() throws {
        let night = rule("Night low", .low, 70, repeatEvery: 5)
        let urgent = rule("Urgent", .low, 55, repeatEvery: 5)
        var e = try engine([night, urgent])
        _ = e.process(TestSupport.reading(54, minute: 0))
        e.acknowledge(ruleID: urgent.id, at: TestSupport.noon)
        let quiet = (1..<29).flatMap { e.process(TestSupport.reading(60, minute: $0)) }
        XCTAssertTrue(quiet.isEmpty, "the covered rule is snoozed too")
    }

    func testConfirmationSurvivesReadingsInTheRearmBand() throws {
        var e = try engine([rule("Night low", .low, 70, confirm: 10)])
        let fired = run(&e, [66, 67, 69, 70, 68, 66, 69, 71, 67, 68, 69, 66, 68])
        XCTAssertEqual(fired.firstIndex { !$0.isEmpty }, 10, "readings of 70 and 71 don't restart the 10 minutes")
    }

    func testRuleTurnedBackOnStartsFresh() throws {
        var high = rule("High", .high, 180)
        var e = try engine([high])
        _ = run(&e, [190])
        high.isEnabled = false
        e.ruleSet = try AlertRuleSet(rules: [high], trendAlerts: [])
        _ = e.process(TestSupport.reading(120, minute: 1))
        high.isEnabled = true
        e.ruleSet = try AlertRuleSet(rules: [high], trendAlerts: [])
        XCTAssertEqual(e.process(TestSupport.reading(195, minute: 2)).map(\.kind), [.initial])
    }

    func testSnoozeSurvivesARelaunch() throws {
        let urgent = rule("Urgent", .low, 60, repeatEvery: 5)
        var e = try engine([urgent])
        _ = e.process(TestSupport.reading(57, minute: 0))
        e.acknowledge(ruleID: urgent.id, at: TestSupport.noon)
        let saved = try JSONEncoder().encode(e.snapshot)

        var relaunched = try engine([urgent])
        relaunched.restore(try JSONDecoder().decode(AlertEngine.Snapshot.self, from: saved), now: TestSupport.noon.addingTimeInterval(60))
        XCTAssertTrue(relaunched.process(TestSupport.reading(57, minute: 1)).isEmpty, "still snoozed")
        XCTAssertFalse(relaunched.log.isEmpty, "the decision log comes back too")
    }

    func testSnoozeFromANotificationAfterARelaunchIsKept() throws {
        let urgent = rule("Urgent", .low, 60, repeatEvery: 5)
        var e = try engine([urgent])   // empty: iOS relaunched the app
        let sentAt = TestSupport.noon
        XCTAssertTrue(e.acknowledge(ruleID: urgent.id, at: sentAt.addingTimeInterval(120), eventDate: sentAt))
        XCTAssertTrue(e.process(TestSupport.reading(57, minute: 3)).isEmpty, "the snooze holds instead of re-alarming")
    }

    func testEveryDecisionIsLogged() throws {
        var e = try engine([rule("L80", .low, 80), rule("L70", .low, 70)])
        _ = run(&e, [65, 90])
        XCTAssertTrue(e.log.contains { $0.contains("suppressed L80") })
        XCTAssertTrue(e.log.contains { $0.contains("fired L70") })
        XCTAssertTrue(e.log.contains { $0.contains("re-armed L70") })
    }
}
