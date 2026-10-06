import XCTest
@testable import GlucoseCore

final class SensorHistoryTests: XCTestCase {
    private let now = TestSupport.noon

    private func sensor(_ id: String, daysAgo: Double = 0) -> SensorHistoryEntry {
        SensorHistoryEntry(id: id, sensorType: "Libre 2 Plus (EU)", computedSerial: "3M\(id)", uidHex: id,
                           startedAt: now.addingTimeInterval(-daysAgo * 86_400), pairedAt: now)
    }

    func testKeepsLastFiveNewestFirst() {
        var history = SensorHistory()
        for i in 1...7 {
            history.record(sensor("S\(i)"), at: now.addingTimeInterval(Double(i) * 86_400))
        }
        XCTAssertEqual(history.entries.map(\.id), ["S7", "S6", "S5", "S4", "S3"])
    }

    func testNewSensorClosesThePreviousOne() {
        var history = SensorHistory()
        history.record(sensor("A"), at: now)
        history.record(sensor("B"), at: now.addingTimeInterval(3600))
        XCTAssertEqual(history.entries[1].endReason, .replaced)
        XCTAssertEqual(history.entries[1].endedAt, now.addingTimeInterval(3600))
        XCTAssertTrue(history.entries[0].isActive)
    }

    func testRePairingKeepsTypedDetails() {
        var history = SensorHistory()
        history.record(sensor("A"), at: now)
        var edited = history.entries[0]
        edited.printedSerial = "0M00ABCDEF"
        edited.note = "Applied on left arm"
        history.update(edited)

        history.record(sensor("A"), at: now.addingTimeInterval(600))
        XCTAssertEqual(history.entries.count, 1)
        XCTAssertEqual(history.entries[0].printedSerial, "0M00ABCDEF")
        XCTAssertEqual(history.entries[0].note, "Applied on left arm")
        XCTAssertTrue(history.entries[0].isActive, "re-pairing doesn't close the same sensor")
    }

    func testManualSensorsGoInByStartDateAndKeepTheCurrentOne() {
        var history = SensorHistory()
        var current = sensor("NOW", daysAgo: 2)
        current.printedSerial = "0M00CURRENT"
        history.record(current, at: now)
        for i in 1...5 {
            history.addManual(sensor("OLD\(i)", daysAgo: Double(i) * 14 + 2), currentID: "NOW")
        }
        XCTAssertEqual(history.entries.map(\.id), ["NOW", "OLD1", "OLD2", "OLD3", "OLD4"],
                       "the current sensor stays first and the oldest-started manual one goes")
        XCTAssertTrue(history.entries[0].isActive, "adding past sensors doesn't close the current one")
        XCTAssertEqual(history.entries[0].printedSerial, "0M00CURRENT")

        // A sensor started after the current one (typed in late) still goes in by date.
        history.addManual(sensor("NEWER", daysAgo: 1), currentID: "NOW")
        XCTAssertEqual(history.entries.first?.id, "NEWER")
        XCTAssertTrue(history.entries.contains { $0.id == "NOW" })
    }

    func testPairingAgainAfterForgetReopensTheSensor() {
        var history = SensorHistory()
        history.record(sensor("A"), at: now)
        var edited = history.entries[0]
        edited.printedSerial = "0M00ABCDEF"
        edited.note = "Left arm"
        history.update(edited)
        history.markEnded(id: "A", at: now.addingTimeInterval(3600), reason: .removedEarly)

        history.record(sensor("A"), at: now.addingTimeInterval(7200), reopen: true)
        XCTAssertTrue(history.entries[0].isActive)
        XCTAssertNil(history.entries[0].endReason)
        XCTAssertEqual(history.entries[0].printedSerial, "0M00ABCDEF")
        XCTAssertEqual(history.entries[0].note, "Left arm")
    }

    func testMarkEndedOnlyOnce() {
        var history = SensorHistory()
        history.record(sensor("A"), at: now)
        history.markEnded(id: "A", at: now.addingTimeInterval(100), reason: .failed)
        history.markEnded(id: "A", at: now.addingTimeInterval(200), reason: .expired)
        XCTAssertEqual(history.entries[0].endReason, .failed)
        XCTAssertEqual(history.entries[0].endedAt, now.addingTimeInterval(100))
    }

    func testSupportText() {
        var entry = sensor("A1B2", daysAgo: 9)
        entry.printedSerial = "0M00ABCDEF"
        entry.endedAt = now
        entry.endReason = .fellOff
        entry.note = "Came off in the shower"
        let text = entry.supportText()
        XCTAssertTrue(text.contains("Serial (printed): 0M00ABCDEF"))
        XCTAssertTrue(text.contains("Sensor UID: A1B2"))
        XCTAssertTrue(text.contains("Reason: Fell off"))
        XCTAssertTrue(text.contains("Worn: 9.0 days"))
        XCTAssertTrue(text.contains("Note: Came off in the shower"))
    }

    func testCodableRoundTrip() throws {
        var history = SensorHistory()
        history.record(sensor("A"), at: now)
        let decoded = try JSONDecoder().decode(SensorHistory.self, from: JSONEncoder().encode(history))
        XCTAssertEqual(decoded, history)
    }
}
