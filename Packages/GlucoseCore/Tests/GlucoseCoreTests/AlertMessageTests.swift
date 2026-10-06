import XCTest
@testable import GlucoseCore

final class AlertMessageTests: XCTestCase {
    private let noon = TestSupport.noon

    private func event(_ value: Double, kind: AlertEvent.Kind = .initial, direction: AlertDirection = .low) -> AlertEvent {
        AlertEvent(ruleID: UUID(), ruleName: "Lower", direction: direction, valueMgdL: value, date: noon,
                   sound: .silent, isCritical: false, criticalVolume: 1, kind: kind)
    }

    private let clock: (Date) -> String = { _ in "3:01 AM" }

    func testTitleCarriesValueAndArrow() {
        XCTAssertEqual(AlertMessage.title(for: event(64), unit: .mgdL, arrow: .falling), "Lower · 64 mg/dL ↘")
        XCTAssertEqual(AlertMessage.title(for: event(64), unit: .mgdL, arrow: .unknown), "Lower · 64 mg/dL")
        XCTAssertEqual(AlertMessage.title(for: event(35), unit: .mmolL, arrow: .fallingQuickly), "Lower · LO ↓")
    }

    func testBodyTellsChangeAndSince() {
        XCTAssertEqual(AlertMessage.body(for: event(64), unit: .mgdL, change15: -9, thresholdMgdL: 70, since: noon, time: clock),
                       "−9 in 15 min. Below 70 since 3:01 AM.")
        XCTAssertEqual(AlertMessage.body(for: event(64, kind: .reminder(count: 2)), unit: .mmolL, change15: 1.8,
                                         thresholdMgdL: 70, since: noon, time: clock),
                       "Reminder 2. +0.1 in 15 min. Below 3.9 since 3:01 AM.")
        XCTAssertEqual(AlertMessage.body(for: event(260, direction: .high), unit: .mgdL, change15: nil, thresholdMgdL: 250,
                                         since: noon, time: clock),
                       "Above 250 since 3:01 AM.")
        XCTAssertEqual(AlertMessage.body(for: event(64), unit: .mgdL, change15: nil, thresholdMgdL: nil, since: nil, time: clock),
                       "Glucose 64 mg/dL", "nothing more to say")
    }

    func testChangeOverFifteenMinutes() {
        let readings = (0...20).map { TestSupport.reading(100 - Double($0), minute: $0) }
        XCTAssertEqual(AlertMessage.change(in: readings), -15)
        XCTAssertNil(AlertMessage.change(in: Array(readings.suffix(5))), "no reading about 15 minutes earlier")
        XCTAssertEqual(AlertMessage.signedChange(0.2, unit: .mgdL), "±0")
        XCTAssertEqual(AlertMessage.signedChange(12, unit: .mgdL), "+12")
    }
}
