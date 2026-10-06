import XCTest
@testable import GlucoseCore

final class QuickLogTests: XCTestCase {
    private let now = TestSupport.noon

    private func ago(_ hours: Double) -> Date { now.addingTimeInterval(-hours * 3600) }

    private func insulin(_ units: Double, _ type: LogEntry.InsulinType = .rapid, hoursAgo: Double) -> LogEntry {
        LogEntry(date: ago(hoursAgo), kind: .insulin(units: units, type: type))
    }

    func testLastInsulinPicksNewestOfType() {
        let entries = [
            insulin(4, hoursAgo: 5),
            insulin(6, hoursAgo: 2),
            insulin(14, .long, hoursAgo: 1),
            LogEntry(date: ago(0.5), kind: .meal(carbsGrams: nil)),
        ]
        let last = QuickLog.lastInsulin(.rapid, in: entries)
        XCTAssertEqual(last?.units, 6)
        XCTAssertEqual(last?.date, ago(2))
        XCTAssertEqual(QuickLog.lastInsulin(.long, in: entries)?.units, 14)
        XCTAssertNil(QuickLog.lastInsulin(.other, in: entries))
    }

    func testLastMeal() {
        let entries = [
            LogEntry(date: ago(3), kind: .meal(carbsGrams: 40)),
            LogEntry(date: ago(1), kind: .meal(carbsGrams: nil)),
            insulin(4, hoursAgo: 0.5),
        ]
        XCTAssertEqual(QuickLog.lastMeal(in: entries), ago(1))
        XCTAssertNil(QuickLog.lastMeal(in: [insulin(4, hoursAgo: 1)]))
    }

    func testUsualDosesAreMostFrequentSortedAscending() {
        let entries = [
            insulin(4, hoursAgo: 1), insulin(4, hoursAgo: 10), insulin(4, hoursAgo: 20),
            insulin(6, hoursAgo: 2), insulin(6, hoursAgo: 30),
            insulin(3, hoursAgo: 3),
            insulin(8, hoursAgo: 4),
            insulin(14, .long, hoursAgo: 5),
        ]
        XCTAssertEqual(QuickLog.usualDoses(.rapid, in: entries, now: now, limit: 3), [3, 4, 6])
        XCTAssertEqual(QuickLog.usualDoses(.rapid, in: entries, now: now), [3, 4, 6, 8])
        XCTAssertEqual(QuickLog.usualDoses(.long, in: entries, now: now), [14])
    }

    func testUsualDosesIgnoreOldEntries() {
        let entries = [insulin(4, hoursAgo: 1), insulin(10, hoursAgo: 24 * 40), insulin(10, hoursAgo: 24 * 41)]
        XCTAssertEqual(QuickLog.usualDoses(.rapid, in: entries, now: now), [4])
        XCTAssertEqual(QuickLog.usualDoses(.rapid, in: [], now: now), [])
    }

    func testFormatDoesNotTrapOnHugeAmounts() {
        XCTAssertEqual(LogEntry.format(12), "12")
        XCTAssertEqual(LogEntry.format(1.5), "1.5")
        XCTAssertFalse(LogEntry.format(1e20).isEmpty, "a 21-digit amount typed by mistake doesn't crash")
        XCTAssertFalse(LogEntry.format(.infinity).isEmpty)
    }
}
