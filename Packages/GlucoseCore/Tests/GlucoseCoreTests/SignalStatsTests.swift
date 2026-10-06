import XCTest
@testable import GlucoseCore

final class SignalStatsTests: XCTestCase {
    private let noon = TestSupport.noon

    private func at(_ minutes: Double) -> Date { noon.addingTimeInterval(minutes * 60) }

    func testCountsPerHourAndSummarises() {
        var stats = SignalStats()
        for minute in 0..<120 {
            stats.recordPacket(at: at(Double(minute)), unusable: minute == 5)
            stats.recordRSSI(minute < 60 ? -70 : -80, at: at(Double(minute)))
        }
        stats.recordCorruptPacket(at: at(30))
        stats.recordReconnect(at: at(90))
        stats.recordRSSI(127, at: at(91)) // "not available"
        XCTAssertEqual(stats.hours.count, 2)

        let summary = stats.summary(in: DateInterval(start: at(0), end: at(120)))
        XCTAssertEqual(summary.packets, 120)
        XCTAssertEqual(summary.corruptPackets, 1)
        XCTAssertEqual(summary.reconnects, 1)
        XCTAssertEqual(summary.unusableValues, 1)
        XCTAssertEqual(summary.averageRSSI ?? 0, -75, accuracy: 0.001)
        XCTAssertEqual(summary.packetShare ?? 0, 1, accuracy: 0.001)
        XCTAssertEqual(SignalStats.SignalQuality(rssi: -75), .good)
        XCTAssertEqual(SignalStats.SignalQuality(rssi: -80), .fair)
        XCTAssertEqual(SignalStats.SignalQuality(rssi: -95), .weak)
    }

    func testPacketShareCountsFromWhenCountingStarted() {
        var stats = SignalStats()
        for minute in 0..<30 where minute % 2 == 0 { stats.recordPacket(at: at(Double(minute)), unusable: false) }
        // Asking about a whole day: only the 30 minutes since counting began are expected.
        let summary = stats.summary(in: DateInterval(start: at(-1410), end: at(30)))
        XCTAssertEqual(summary.minutes, 30, accuracy: 0.001)
        XCTAssertEqual(summary.packetShare ?? 0, 0.5, accuracy: 0.001)
    }

    func testOutagesOpenCloseAndKeepTheBestReason() {
        var stats = SignalStats()
        stats.recordPacket(at: at(0), unusable: false)
        stats.linkLost(at: at(1), reason: .linkLost)
        stats.linkLost(at: at(3), reason: .bluetoothOff) // the same outage, now explained
        stats.recordPacket(at: at(31), unusable: false)
        XCTAssertEqual(stats.outages.count, 1)
        XCTAssertEqual(stats.outages[0].reason, .bluetoothOff)
        XCTAssertEqual(stats.outages[0].end, at(31))

        // A short drop is a normal reconnect and isn't kept.
        stats.linkLost(at: at(40), reason: .linkLost)
        stats.recordPacket(at: at(41), unusable: false)
        XCTAssertEqual(stats.outages.count, 1)

        stats.linkLost(at: at(50), reason: .appPaused)
        let open = stats.outages(in: DateInterval(start: at(0), end: at(100)), now: at(100))
        XCTAssertEqual(open.map(\.reason), [.appPaused, .bluetoothOff], "newest first, the open one included")
    }

    func testPruneDropsOldHoursAndOutages() {
        var stats = SignalStats()
        stats.recordPacket(at: at(0), unusable: false)
        stats.linkLost(at: at(1), reason: .linkLost)
        stats.recordPacket(at: at(20), unusable: false)
        stats.prune(now: at(17 * 1440))
        XCTAssertTrue(stats.hours.isEmpty)
        XCTAssertTrue(stats.outages.isEmpty)
    }

    func testDataGapsAndCoverage() {
        let readings = (0..<60).map { TestSupport.reading(100, minute: $0) }
            + (120..<180).map { TestSupport.reading(100, minute: $0) }
        let gaps = SignalStats.dataGaps(in: readings, interval: DateInterval(start: at(0), end: at(240)))
        XCTAssertEqual(gaps, [DateInterval(start: at(179), end: at(240)), DateInterval(start: at(59), end: at(120))])

        // NFC history: one value per 15 minutes still covers the stretch.
        let nfc = stride(from: 60, to: 120, by: 15).map { TestSupport.reading(100, minute: $0, source: .nfc) }
        XCTAssertTrue(SignalStats.isCovered(DateInterval(start: at(60), end: at(120)), by: nfc))
        XCTAssertFalse(SignalStats.isCovered(DateInterval(start: at(60), end: at(120)), by: Array(nfc.prefix(2))))
    }

    func testNoiseLevel() {
        let smooth = (0..<60).map { TestSupport.reading(100 + Double($0) * 0.5, minute: $0) }
        XCTAssertEqual(SignalStats.noise(in: smooth)?.level, .low)
        let jittery = (0..<60).map { TestSupport.reading(100 + ($0.isMultiple(of: 2) ? 4 : -4), minute: $0) }
        XCTAssertEqual(SignalStats.noise(in: jittery)?.level, .high)
        XCTAssertNil(SignalStats.noise(in: Array(smooth.prefix(10))), "too few minutes to tell")
    }

    func testWearDays() {
        // Day 1 fully covered after warm-up, day 2 half covered, now in the middle of day 3.
        let start = noon
        var readings = (60..<1440).map { TestSupport.reading(100, minute: $0, start: start) }
        readings += (1440..<2160).map { TestSupport.reading(100, minute: $0, start: start) }
        readings += (2880..<3000).map { TestSupport.reading(100, minute: $0, start: start) }
        let now = start.addingTimeInterval(3000 * 60)
        let sticks = [FingerstickEntry(date: start.addingTimeInterval(1500 * 60), mgdL: 100, usedForCalibration: true,
                                       sensorSerial: "TEST")]
        let check = AccuracyReport.Pair(date: start.addingTimeInterval(1600 * 60), referenceMgdL: 100, sensorMgdL: 110,
                                        sensorSerial: "TEST")
        let days = SensorWear.days(readings: readings, sensorSerial: "TEST", activatedAt: start, lifetimeDays: 15,
                                   fingersticks: sticks, accuracy: AccuracyReport(pairs: [check]), now: now)
        XCTAssertEqual(days.count, 15)
        XCTAssertEqual(days[0].coverage ?? 0, 1, accuracy: 0.001)
        XCTAssertEqual(days[1].coverage ?? 0, 0.5, accuracy: 0.001)
        XCTAssertEqual(days[1].calibrations, 1)
        XCTAssertEqual(days[1].accuracy?.mard ?? 0, 10, accuracy: 0.001)
        XCTAssertEqual(days[1].accuracy?.count, 1)
        XCTAssertNil(days[0].accuracy)
        XCTAssertEqual(days[2].coverage ?? 0, 1, accuracy: 0.001, "today so far")
        XCTAssertTrue(days[2].isToday)
        XCTAssertNil(days[3].coverage, "days still ahead")
    }

    func testWearDaysCanStartLaterInTheSensorsMinutes() {
        // The demo's sensor has run for weeks; its "wear" starts at minute 10,000.
        let first = 10_000
        let start = noon.addingTimeInterval(Double(first) * 60)
        let readings = (first..<(first + 1500)).map { TestSupport.reading(100, minute: $0) }
        let days = SensorWear.days(readings: readings, sensorSerial: "TEST", activatedAt: start, lifetimeDays: 15,
                                   fingersticks: [], accuracy: AccuracyReport(pairs: []),
                                   now: start.addingTimeInterval(1500 * 60), firstMinute: first)
        XCTAssertEqual(days[0].coverage ?? 0, 1, accuracy: 0.001)
        XCTAssertTrue(days[1].isToday)
    }

    func testPacketShareNeverPassesOneHundredPercent() {
        var stats = SignalStats()
        for minute in 0..<120 { stats.recordPacket(at: at(Double(minute)), unusable: false) }
        // Half past: the first hour is counted whole, and so are its expected minutes.
        let summary = stats.summary(in: DateInterval(start: at(30), end: at(120)))
        XCTAssertEqual(summary.packets, 120)
        XCTAssertEqual(summary.minutes, 120, accuracy: 0.001)
        XCTAssertEqual(summary.packetShare ?? 0, 1, accuracy: 0.001)
    }

    func testEndingAnOutageAndKeepingItsFirstReason() {
        var stats = SignalStats()
        stats.linkLost(at: at(0), reason: .bluetoothOff)
        stats.linkLost(at: at(5), reason: .appPaused)
        XCTAssertEqual(stats.outages.last?.reason, .bluetoothOff)
        stats.endOpenOutage(at: at(30))
        XCTAssertEqual(stats.outages.last?.end, at(30))
        stats.recordPacket(at: at(40), unusable: false)
        XCTAssertEqual(stats.outages.last?.end, at(30), "a closed outage stays as it was")
    }

    func testNotReadingTimeIsNeitherMissedNorAGap() {
        var stats = SignalStats()
        for minute in 0..<60 { stats.recordPacket(at: at(Double(minute)), unusable: false) }
        stats.pauseCounting(at: at(60))   // switched to the demo for an hour
        stats.resumeCounting(at: at(120))
        for minute in 120..<180 { stats.recordPacket(at: at(Double(minute)), unusable: false) }
        let summary = stats.summary(in: DateInterval(start: at(0), end: at(180)))
        XCTAssertEqual(summary.minutes, 120, accuracy: 0.001, "the demo hour expects no packets")
        XCTAssertEqual(summary.packetShare ?? 0, 1, accuracy: 0.001)
        XCTAssertTrue(stats.isNotReading(during: DateInterval(start: at(65), end: at(110)), now: at(180)))
        XCTAssertFalse(stats.isNotReading(during: DateInterval(start: at(10), end: at(50)), now: at(180)))
    }

    func testAnOutageLeftOpenEndsAtTheLastSave() throws {
        var stats = SignalStats()
        stats.recordPacket(at: at(0), unusable: false)
        stats.linkLost(at: at(5), reason: .linkLost)
        stats.savedAt = at(20)
        // Saved and reloaded, as after the app was killed.
        var reloaded = try JSONDecoder().decode(SignalStats.self, from: JSONEncoder().encode(stats))
        reloaded.closeOutageLeftOpen()
        XCTAssertEqual(reloaded.outages.last?.end, at(20))
    }

    func testStatsSavedBeforePausesExistedStillLoad() throws {
        let old = Data(#"{"hours":[],"outages":[]}"#.utf8)
        let stats = try JSONDecoder().decode(SignalStats.self, from: old)
        XCTAssertTrue(stats.pauses.isEmpty)
    }
}
