import XCTest
@testable import GlucoseCore

final class StorageAndExportTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("archive-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testArchiveAppendLoadAcrossDays() throws {
        let archive = try ReadingArchive(directory: directory)
        // 12:00 UTC on day 1 through 12:00 on day 2, every 60 minutes.
        let readings = (0...24).map { TestSupport.reading(100 + Double($0), minute: $0 * 60) }
        try archive.append(Array(readings.prefix(10)))
        try archive.append(Array(readings.dropFirst(10)))

        let all = try archive.load(from: TestSupport.noon, to: TestSupport.noon.addingTimeInterval(24 * 3600))
        XCTAssertEqual(all.count, 25)
        XCTAssertEqual(all.first?.mgdL, 100)
        XCTAssertEqual(all.last?.mgdL, 124)

        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(files.count, 2, "one file per UTC day")

        let window = try archive.load(from: TestSupport.noon.addingTimeInterval(3600), to: TestSupport.noon.addingTimeInterval(3 * 3600))
        XCTAssertEqual(window.map(\.mgdL), [101, 102, 103])
    }

    func testArchiveDeduplicatesOnLoad() throws {
        let archive = try ReadingArchive(directory: directory)
        try archive.append([TestSupport.reading(100, minute: 5, source: .backfill)])
        try archive.append([TestSupport.reading(104, minute: 5, source: .bluetooth)])
        let loaded = try archive.load(from: TestSupport.noon, to: TestSupport.noon.addingTimeInterval(3600))
        XCTAssertEqual(loaded.map(\.mgdL), [104])
    }

    func testArchivePrune() throws {
        let archive = try ReadingArchive(directory: directory)
        try archive.append([TestSupport.reading(100, minute: 0), TestSupport.reading(110, minute: 3 * 1440)])
        try archive.prune(olderThan: TestSupport.noon.addingTimeInterval(2 * 86_400))
        let loaded = try archive.load(from: TestSupport.noon.addingTimeInterval(-86_400), to: TestSupport.noon.addingTimeInterval(4 * 86_400))
        XCTAssertEqual(loaded.map(\.mgdL), [110])
        try archive.removeAll()
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    func testJSONFileStore() throws {
        let store = JSONFileStore<[LogEntry]>(url: directory.appendingPathComponent("log.json"))
        XCTAssertNil(store.load())
        let entries = [LogEntry(date: TestSupport.noon, kind: .insulin(units: 4.5, type: .rapid), text: "lunch")]
        try store.save(entries)
        XCTAssertEqual(store.load(), entries)
        store.delete()
        XCTAssertNil(store.load())
    }

    func testLogEntryTitles() {
        XCTAssertEqual(LogEntry(date: TestSupport.noon, kind: .meal(carbsGrams: 45)).title, "Food · 45 g carbs")
        XCTAssertEqual(LogEntry(date: TestSupport.noon, kind: .insulin(units: 2.5, type: .rapid)).title, "Fast-acting insulin · 2.5 U")
        XCTAssertEqual(LogEntry(date: TestSupport.noon, kind: .insulin(units: 12, type: .long)).title, "Slow-acting insulin · 12 U")
        XCTAssertEqual(LogEntry(date: TestSupport.noon, kind: .exercise(minutes: 30)).title, "Exercise · 30 min")
    }

    func testCSVExports() {
        let csv = CSVExport.readings([TestSupport.reading(108.1, minute: 1), TestSupport.reading(90, minute: 0)])
        let lines = csv.split(separator: "\n")
        XCTAssertEqual(lines.first, "timestamp,glucose_mgdl,glucose_mmoll,source,sensor")
        XCTAssertEqual(lines[1], "2026-01-05T12:00:00Z,90,5.0,bluetooth,TEST")
        XCTAssertEqual(lines[2], "2026-01-05T12:01:00Z,108,6.0,bluetooth,TEST")

        let log = CSVExport.logbook([LogEntry(date: TestSupport.noon, kind: .meal(carbsGrams: 30), text: "pasta, \"big\"")])
        XCTAssertTrue(log.contains(#"2026-01-05T12:00:00Z,meal,30,"pasta, ""big""""#))

        let sticks = CSVExport.fingersticks([FingerstickEntry(date: TestSupport.noon, mgdL: 99.6, usedForCalibration: true)])
        XCTAssertTrue(sticks.contains("2026-01-05T12:00:00Z,100,true"))
    }

    func testDayNightSplit() {
        // 12:00 UTC start: 10 hours of day (12-22), then 8 hours of night (22-06).
        let readings = (0..<(18 * 60)).map { TestSupport.reading($0 < 600 ? 120 : 200, minute: $0) }
        let period = DateInterval(start: TestSupport.noon, duration: 24 * 3600)
        let split = DailyPatterns.dayNight(readings, period: period, calendar: TestSupport.utc)
        XCTAssertEqual(split.day?.meanMgdL, 120)
        XCTAssertEqual(split.night?.meanMgdL, 200)
        XCTAssertEqual(split.day?.count, 600)
        XCTAssertEqual(split.night?.count, 480)
        XCTAssertEqual(split.night?.dataSufficiency ?? 0, 1, accuracy: 0.0001)
    }

    func testDailyOverlay() {
        let readings = (0..<(2 * 1440)).map { TestSupport.reading(100, minute: $0) }
        let days = DailyPatterns.overlay(readings, stepMinutes: 5, calendar: TestSupport.utc)
        XCTAssertEqual(days.count, 3, "noon day 1 to noon day 3 spans three calendar days")
        XCTAssertEqual(days[1].points.count, 288)
        XCTAssertEqual(days[0].points.first?.minuteOfDay, 720)
    }

    func testSensorReminders() {
        let expires = TestSupport.noon.addingTimeInterval(10 * 3600)
        let reminders = SensorLifecycle.reminders(expiresAt: expires, now: TestSupport.noon)
        XCTAssertEqual(reminders.map(\.title), ["Sensor ends in 2 hours", "Sensor ended"])
    }
}
