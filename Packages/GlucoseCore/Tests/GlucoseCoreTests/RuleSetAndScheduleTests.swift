import XCTest
@testable import GlucoseCore

final class RuleSetAndScheduleTests: XCTestCase {
    func testMaxFiveRulesPerDirection() throws {
        var set = try AlertRuleSet()
        for threshold in stride(from: 50.0, through: 90, by: 10) {
            try set.add(AlertRule(name: "L\(threshold)", direction: .low, thresholdMgdL: threshold, sound: .silent))
        }
        XCTAssertThrowsError(try set.add(AlertRule(name: "L95", direction: .low, thresholdMgdL: 95, sound: .silent))) {
            XCTAssertEqual($0 as? AlertRuleSet.RuleSetError, .tooManyRules(.low))
        }
        // Highs have their own budget.
        XCTAssertNoThrow(try set.add(AlertRule(name: "H", direction: .high, thresholdMgdL: 180, sound: .silent)))
    }

    func testRejectsOutOfRangeThreshold() {
        XCTAssertThrowsError(try AlertRuleSet(rules: [
            AlertRule(name: "Bad", direction: .low, thresholdMgdL: 20, sound: .silent),
        ]))
    }

    func testValidationWarnings() throws {
        let set = try AlertRuleSet(rules: [
            AlertRule(name: "A", direction: .low, thresholdMgdL: 70, sound: .silent),
            AlertRule(name: "B", direction: .low, thresholdMgdL: 70, sound: .silent),
            AlertRule(name: "H", direction: .high, thresholdMgdL: 65, sound: .silent),
        ])
        let issues = set.validate()
        XCTAssertTrue(issues.contains(.duplicateThreshold(.low, 70)))
        XCTAssertTrue(issues.contains(.lowAboveHigh(lowMgdL: 70, highMgdL: 65)))
        XCTAssertTrue(issues.contains(.noUrgentLow))
    }

    func testNightOnlyUrgentLowDoesNotCountAsSafeguard() throws {
        let set = try AlertRuleSet(rules: [
            AlertRule(name: "Lower", direction: .low, thresholdMgdL: 70, sound: .silent),
            AlertRule(name: "Urgent", direction: .low, thresholdMgdL: 55, sound: .silent, schedule: .nightOnly),
        ])
        XCTAssertTrue(set.urgentLowRules.isEmpty)
        XCTAssertTrue(set.validate().contains(.noUrgentLow))
    }

    func testApplyingAPresetKeepsTrendAlertsAndRuleIDs() {
        var current = AlertRuleSet.basic()
        current.trendAlerts[1].isEnabled = true   // Falling fast
        let night = current.applyingPreset(.night())
        XCTAssertEqual(night.trendAlerts, current.trendAlerts)
        XCTAssertEqual(night.rules.map(\.name), AlertRuleSet.night().rules.map(\.name))
        let urgentID = current.rules.first { $0.name == "Urgent low" }?.id
        XCTAssertEqual(night.rules.first { $0.name == "Urgent low" }?.id, urgentID)
        XCTAssertEqual(current.applyingPreset(.basic()).rules.map(\.id), current.rules.map(\.id),
                       "re-applying the same preset keeps every id")
    }

    func testPresetsAreValid() {
        for preset in [AlertRuleSet.basic(), .night(), .sensitive()] {
            XCTAssertEqual(preset.validate(), [], "preset should have no warnings")
            XCTAssertLessThanOrEqual(preset.rules(for: .low).count, AlertRuleSet.maxRulesPerDirection)
            XCTAssertLessThanOrEqual(preset.rules(for: .high).count, AlertRuleSet.maxRulesPerDirection)
        }
    }

    func testBasicPresetMatchesPlanExample() {
        let lows = AlertRuleSet.basic().rules(for: .low)
        XCTAssertEqual(lows.map(\.thresholdMgdL), [80, 70, 60])
        XCTAssertEqual(lows.map(\.sound), [.silent, .tune(name: "alarm_loud_low"), .voice(clip: "glucose_very_low")])
    }

    func testDuplicate() throws {
        var set = AlertRuleSet.basic()
        let id = set.rules(for: .low)[0].id
        try set.duplicate(id: id)
        XCTAssertEqual(set.rules(for: .low).count, 4)
        XCTAssertEqual(Set(set.rules.map(\.id)).count, set.rules.count)
    }

    func testRuleSetCodableRoundTrip() throws {
        let set = AlertRuleSet.basic()
        let data = try JSONEncoder().encode(set)
        XCTAssertEqual(try JSONDecoder().decode(AlertRuleSet.self, from: data), set)
    }

    func testScheduleSimpleWindow() {
        let schedule = AlertSchedule(startMinute: 9 * 60, endMinute: 17 * 60)
        let cal = TestSupport.utc
        XCTAssertTrue(schedule.isActive(at: TestSupport.noon, calendar: cal))
        XCTAssertFalse(schedule.isActive(at: TestSupport.noon.addingTimeInterval(6 * 3600), calendar: cal))
    }

    func testWrappingWindowUsesPreviousDayAfterMidnight() {
        // Night window only on Monday (weekday 2). Noon is Monday 12:00 UTC.
        let schedule = AlertSchedule(weekdays: [2], startMinute: 22 * 60, endMinute: 7 * 60)
        let cal = TestSupport.utc
        let mondayLate = TestSupport.noon.addingTimeInterval(11 * 3600)     // Mon 23:00
        let tuesdayEarly = TestSupport.noon.addingTimeInterval(15 * 3600)   // Tue 03:00
        let mondayEarly = TestSupport.noon.addingTimeInterval(-9 * 3600)    // Mon 03:00 (Sunday's window)
        XCTAssertTrue(schedule.isActive(at: mondayLate, calendar: cal))
        XCTAssertTrue(schedule.isActive(at: tuesdayEarly, calendar: cal))
        XCTAssertFalse(schedule.isActive(at: mondayEarly, calendar: cal))
    }

    func testMissingDataFireDates() {
        let alert = MissingDataAlert(minutes: 15, repeatIntervalMinutes: 10)
        let last = TestSupport.noon
        let dates = alert.fireDates(lastReading: last, calendar: TestSupport.utc)
        XCTAssertEqual(dates.first, last.addingTimeInterval(15 * 60))
        XCTAssertEqual(dates.count, MissingDataAlert.maxScheduledNotifications)
        XCTAssertEqual(dates[1].timeIntervalSince(dates[0]), 10 * 60)
    }

    func testMissingDataRespectsWarmUpAndGrace() {
        let alert = MissingDataAlert(minutes: 15, repeatIntervalMinutes: nil, graceMinutesAfterRestart: 30)
        let last = TestSupport.noon
        let warmUp = alert.fireDates(lastReading: last, warmUpEnds: last.addingTimeInterval(3600), calendar: TestSupport.utc)
        XCTAssertEqual(warmUp, [last.addingTimeInterval(75 * 60)])
        let grace = alert.fireDates(lastReading: last, restartedAt: last, calendar: TestSupport.utc)
        XCTAssertEqual(grace, [last.addingTimeInterval(30 * 60)])
    }

    func testMissingDataMinutesAreClamped() {
        var alert = MissingDataAlert(minutes: 1)
        XCTAssertEqual(alert.minutes, 5)
        alert.minutes = 999
        XCTAssertEqual(alert.minutes, 180)
        alert.isEnabled = false
        XCTAssertEqual(alert.fireDates(lastReading: TestSupport.noon), [])
    }
}
