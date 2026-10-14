import XCTest
@testable import GlucoseCore

final class InsulinOnBoardTests: XCTestCase {
    private let now = TestSupport.noon

    private func ago(_ minutes: Double) -> Date {
        now.addingTimeInterval(-minutes * 60)
    }

    private func dose(_ units: Double, minutesAgo: Double, type: LogEntry.InsulinType = .rapid) -> LogEntry {
        LogEntry(date: ago(minutesAgo), kind: .insulin(units: units, type: type))
    }

    func testCurveStartsFullAndRunsOutAfterFiveHours() {
        let curve = InsulinCurve.rapid
        XCTAssertEqual(curve.remaining(afterMinutes: 0), 1, accuracy: 1e-9)
        XCTAssertEqual(curve.remaining(afterMinutes: 60), 0.764, accuracy: 0.001)
        XCTAssertEqual(curve.remaining(afterMinutes: 120), 0.411, accuracy: 0.001)
        XCTAssertEqual(curve.remaining(afterMinutes: 180), 0.159, accuracy: 0.001)
        XCTAssertEqual(curve.remaining(afterMinutes: 300), 0)
        XCTAssertEqual(curve.remaining(afterMinutes: -5), 0, "a dose not taken yet")
        var previous = 1.0
        for minute in stride(from: 5.0, to: 300, by: 5) {
            let remaining = curve.remaining(afterMinutes: minute)
            XCTAssertLessThan(remaining, previous, "falls all the way, at \(minute) min")
            previous = remaining
        }
    }

    func testOnlyFastInsulinStillWorkingCounts() {
        let entries = [
            dose(6, minutesAgo: 60),
            dose(2, minutesAgo: 120),
            dose(14, minutesAgo: 30, type: .long),
            dose(4, minutesAgo: 400),
            dose(3, minutesAgo: -20),
            LogEntry(date: ago(10), kind: .meal(carbsGrams: 50)),
        ]
        let curve = InsulinCurve.rapid
        XCTAssertEqual(InsulinOnBoard.units(at: now, in: entries),
                       6 * curve.remaining(afterMinutes: 60) + 2 * curve.remaining(afterMinutes: 120), accuracy: 1e-9,
                       "slow insulin, a dose used up and one taken later don't count")
        XCTAssertEqual(InsulinOnBoard.doses(at: now, in: entries).map(\.date), [ago(120), ago(60)], "oldest first")
        XCTAssertEqual(LogContext.at(now, in: entries).minutesSinceInsulin ?? 0, 60, accuracy: 0.001, "the newest dose")
    }

    func testInsulinOfUnknownTypeCountsAsFast() {
        XCTAssertEqual(InsulinOnBoard.units(at: now, in: [dose(4, minutesAgo: 60, type: .other)]), 3.056, accuracy: 0.001)
    }

    func testWhenInsulinIsMostlyDone() {
        let time = InsulinOnBoard.time(whenBelow: InsulinOnBoard.activeUnits, after: now, in: [dose(6, minutesAgo: 0)])
        XCTAssertEqual((time?.timeIntervalSince(now) ?? 0) / 60, 210, accuracy: 1)
        XCTAssertNil(InsulinOnBoard.time(whenBelow: InsulinOnBoard.activeUnits, after: now, in: [dose(1, minutesAgo: 240)]),
                     "already below")
    }

    func testLogContextFindsFoodAndExercise() {
        let context = LogContext.at(now, in: [
            LogEntry(date: ago(50), kind: .meal(carbsGrams: 40)),
            LogEntry(date: ago(200), kind: .meal(carbsGrams: 30)),
            LogEntry(date: ago(90), kind: .exercise(minutes: 45)),
            LogEntry(date: ago(5), kind: .note, text: "Feeling fine"),
        ])
        XCTAssertEqual(context.foods.count, 1, "food over 3 hours ago doesn't matter")
        XCTAssertEqual(context.minutesSinceFood ?? 0, 50, accuracy: 0.001)
        XCTAssertEqual(context.minutesSinceExercise ?? -1, 45, accuracy: 0.001, "45 minutes since it ended")
        XCTAssertEqual(context.insulinOnBoard, 0)

        let during = LogContext.at(now, in: [LogEntry(date: ago(10), kind: .exercise(minutes: 30))])
        XCTAssertEqual(during.minutesSinceExercise, 0)
        let longAgo = LogContext.at(now, in: [LogEntry(date: ago(120), kind: .exercise(minutes: 30))])
        XCTAssertNil(longAgo.minutesSinceExercise, "ended an hour and a half ago")
    }
}
