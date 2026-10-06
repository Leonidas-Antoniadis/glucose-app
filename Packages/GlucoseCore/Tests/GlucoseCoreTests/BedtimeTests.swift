import XCTest
@testable import GlucoseCore

final class BedtimeTests: XCTestCase {
    private let noon = TestSupport.noon // Monday 2026-01-05 12:00 UTC
    private let utc = TestSupport.utc

    private func input() -> BedtimeInputs {
        var input = BedtimeInputs(now: noon, morning: noon.addingTimeInterval(19 * 3600))
        input.mediaVolume = 0.8
        input.batteryLevel = 0.9
        input.missingDataMinutes = 20
        input.urgentLowSoundsThroughSilent = true
        input.sensorEndsAt = noon.addingTimeInterval(6 * 86_400)
        input.buildExpiresAt = noon.addingTimeInterval(5 * 86_400 + 60)
        return input
    }

    private func check(_ input: BedtimeInputs) -> [BedtimeItem] {
        BedtimeCheck.items(input, calendar: utc, time: { _ in "3:10 AM" })
    }

    func testLateBedtimeWindow() {
        func at(_ hour: Int, _ minute: Int) -> Date {
            utc.date(bySettingHour: hour, minute: minute, second: 0, of: noon)!
        }
        // Bedtime 00:30: from 23:30 to 04:00, never all day.
        XCTAssertFalse(BedtimeCheck.isEvening(at(10, 0), bedtimeMinutes: 30, calendar: utc))
        XCTAssertFalse(BedtimeCheck.isEvening(at(23, 29), bedtimeMinutes: 30, calendar: utc))
        XCTAssertTrue(BedtimeCheck.isEvening(at(23, 30), bedtimeMinutes: 30, calendar: utc))
        XCTAssertTrue(BedtimeCheck.isEvening(at(3, 59), bedtimeMinutes: 30, calendar: utc))
        XCTAssertFalse(BedtimeCheck.isEvening(at(4, 0), bedtimeMinutes: 30, calendar: utc))
        // Bedtime 05:00: at least 4 hours from 04:00, so until 08:00.
        XCTAssertTrue(BedtimeCheck.isEvening(at(7, 59), bedtimeMinutes: 5 * 60, calendar: utc))
        XCTAssertFalse(BedtimeCheck.isEvening(at(8, 0), bedtimeMinutes: 5 * 60, calendar: utc))
        XCTAssertFalse(BedtimeCheck.isEvening(at(12, 0), bedtimeMinutes: 5 * 60, calendar: utc))
        // The window started the evening before: 01:00 belongs to the night that began at 23:30.
        let window = BedtimeCheck.eveningWindow(containing: at(1, 0), bedtimeMinutes: 30, calendar: utc)
        XCTAssertEqual(window?.start, at(1, 0).addingTimeInterval(-90 * 60))
    }

    func testWordingForNotificationsUrgentLowAndBuild() {
        var input = input()
        input.notificationsAllowed = false
        input.notificationProblem = "Notification sounds are off for this app, so alerts are silent."
        input.hasAllDayUrgentLow = false
        input.now = utc.date(bySettingHour: 1, minute: 0, second: 0, of: noon)!
        input.morning = utc.date(bySettingHour: 7, minute: 0, second: 0, of: noon)!
        input.buildExpiresAt = utc.date(bySettingHour: 18, minute: 0, second: 0, of: noon)!
        let items = check(input)
        XCTAssertEqual(items.first { $0.id == "notifications" }?.detail, input.notificationProblem)
        XCTAssertEqual(items.first { $0.id == "silent" }?.title, "No all-day urgent-low alert")
        XCTAssertEqual(items.first { $0.id == "build" }?.title, "App build expires today at 3:10 AM",
                       "the same calendar day, not tomorrow")
    }

    func testAllClear() {
        let items = check(input())
        XCTAssertTrue(items.allSatisfy { $0.status == .ok }, items.map(\.title).description)
        XCTAssertEqual(items.first { $0.id == "missing" }?.title, "No-data alert armed (20 min)")
        XCTAssertEqual(items.first { $0.id == "build" }?.title, "App build valid 5 days")
    }

    func testProblemsComeFirst() {
        var input = input()
        input.mediaVolume = 0.15
        input.batteryLevel = 0.18
        input.missingDataMinutes = nil
        let items = check(input)
        XCTAssertEqual(items.prefix(3).map(\.id), ["volume", "battery", "missing"])
        XCTAssertEqual(items[0].status, .problem)
        XCTAssertEqual(items[0].title, "Media volume 15%")
        XCTAssertEqual(items[0].fix, .raiseVolume)
        XCTAssertEqual(items[1].title, "Battery 18% · not charging")
        XCTAssertEqual(items[2].status, .warning)

        input.isCharging = true
        XCTAssertEqual(check(input).first { $0.id == "battery" }?.status, .ok, "charging is fine whatever the level")
    }

    func testSensorEndingTonightAndConnection() {
        var input = input()
        input.sensorEndsAt = noon.addingTimeInterval(15 * 3600) // 3 AM
        input.sensorConnected = false
        let items = check(input)
        let sensor = items.first { $0.id == "sensor" }
        XCTAssertEqual(sensor?.status, .problem)
        XCTAssertEqual(sensor?.title, "Sensor ends at 3:10 AM")
        XCTAssertEqual(items.first { $0.id == "bluetooth" }?.status, .problem)

        input.bluetoothOn = false
        XCTAssertEqual(check(input).first { $0.id == "bluetooth" }?.title, "Bluetooth is off")

        input.isDemo = true
        XCTAssertNil(check(input).first { $0.id == "bluetooth" }, "the demo has no Bluetooth to check")
        XCTAssertNil(check(input).first { $0.id == "sensor" })
    }

    func testBuildExpiringTonight() {
        var input = input()
        input.buildExpiresAt = noon.addingTimeInterval(10 * 3600)
        XCTAssertEqual(check(input).first?.id, "build")
        XCTAssertEqual(check(input).first?.status, .problem)
    }

    func testEveningWindowAndMorning() {
        func at(_ hour: Int, _ minute: Int) -> Date {
            utc.date(bySettingHour: hour, minute: minute, second: 0, of: noon)!
        }
        XCTAssertTrue(BedtimeCheck.isEvening(at(21, 0), bedtimeMinutes: 22 * 60, calendar: utc))
        XCTAssertFalse(BedtimeCheck.isEvening(at(20, 59), bedtimeMinutes: 22 * 60, calendar: utc))
        XCTAssertTrue(BedtimeCheck.isEvening(at(3, 59), bedtimeMinutes: 22 * 60, calendar: utc))
        XCTAssertFalse(BedtimeCheck.isEvening(at(4, 0), bedtimeMinutes: 22 * 60, calendar: utc))
        XCTAssertEqual(BedtimeCheck.morning(after: noon, hour: 7, calendar: utc), noon.addingTimeInterval(19 * 3600))
    }

    func testNightLows() {
        let today6 = utc.date(bySettingHour: 6, minute: 0, second: 0, of: noon)!
        var readings: [GlucoseReading] = []
        for night in 0..<3 {
            let end = today6.addingTimeInterval(-Double(night) * 86_400)
            let start = end.addingTimeInterval(-8 * 3600)
            for minute in stride(from: 0, to: 480, by: 5) {
                let time = start.addingTimeInterval(Double(minute) * 60)
                let hour = utc.component(.hour, from: time)
                let low = night < 2 && hour == 3 && utc.component(.minute, from: time) < 30
                readings.append(TestSupport.reading(low ? 60 : 120, minute: minute, start: start))
            }
        }
        let summary = NightLowSummary.make(readings: readings, now: noon, calendar: utc)
        XCTAssertEqual(summary.nightsWithData, 3)
        XCTAssertEqual(summary.nightsWithLows, 2)
        XCTAssertEqual(summary.typicalHour, 3)
    }
}
