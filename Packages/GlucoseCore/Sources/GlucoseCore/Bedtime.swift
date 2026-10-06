import Foundation

/// What the bedtime check looks at: everything that could keep an alarm from being heard tonight.
public struct BedtimeInputs: Sendable {
    /// Media volume, 0...1: the app plays its own alarm at this volume. Nil when unknown.
    public var mediaVolume: Double?
    /// Battery level, 0...1. Nil when unknown.
    public var batteryLevel: Double?
    public var isCharging = false
    public var bluetoothOn = true
    /// A reading arrived in the last 10 minutes.
    public var sensorConnected = true
    public var isDemo = false
    public var runInBackground = true
    public var notificationsAllowed = true
    /// The no-data alert's delay, nil when it's off.
    public var missingDataMinutes: Int?
    /// An all-day urgent-low alert sounds through Silent mode and Focus.
    public var urgentLowSoundsThroughSilent = false
    public var sensorEndsAt: Date?
    public var buildExpiresAt: Date?
    public var now: Date
    /// When the night ends, for "the sensor ends before morning".
    public var morning: Date

    public init(now: Date, morning: Date) {
        self.now = now
        self.morning = morning
    }
}

/// One line of the bedtime check.
public struct BedtimeItem: Identifiable, Hashable, Sendable {
    public enum Status: Int, Comparable, Sendable {
        case problem, warning, ok
        public static func < (lhs: Status, rhs: Status) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// What the app can offer to fix it.
    public enum Fix: Sendable {
        case raiseVolume, charge, bluetooth, openSensor, notificationSettings, runInBackground,
             missingDataAlert, urgentLowThroughSilent, newBuild, none
    }

    public let id: String
    public let status: Status
    public let title: String
    public let detail: String
    public let fix: Fix
}

public enum BedtimeCheck {
    /// The checks, the ones that need fixing first.
    public static func items(_ input: BedtimeInputs, time: (Date) -> String) -> [BedtimeItem] {
        var items: [BedtimeItem] = []

        if let volume = input.mediaVolume {
            let percent = Int((volume * 100).rounded())
            items.append(BedtimeItem(
                id: "volume", status: volume < 0.3 ? .problem : volume < 0.6 ? .warning : .ok,
                title: "Media volume \(percent)%",
                detail: volume < 0.6 ? "Alarms the app plays use this volume. Raise it before you sleep." : "Alarms the app plays use this volume.",
                fix: volume < 0.6 ? .raiseVolume : .none))
        }

        if let level = input.batteryLevel {
            let percent = Int((level * 100).rounded())
            if input.isCharging {
                items.append(BedtimeItem(id: "battery", status: .ok, title: "Battery \(percent)% · charging", detail: "", fix: .none))
            } else {
                let status: BedtimeItem.Status = level < 0.3 ? .problem : level < 0.5 ? .warning : .ok
                items.append(BedtimeItem(id: "battery", status: status, title: "Battery \(percent)% · not charging",
                                         detail: status == .ok ? "" : "Plug in before you sleep: a dead phone sounds no alarm.",
                                         fix: status == .ok ? .none : .charge))
            }
        }

        if !input.isDemo {
            if !input.bluetoothOn {
                items.append(BedtimeItem(id: "bluetooth", status: .problem, title: "Bluetooth is off",
                                         detail: "Turn it on in Control Center, or no readings arrive overnight.", fix: .bluetooth))
            } else if !input.sensorConnected {
                items.append(BedtimeItem(id: "bluetooth", status: .problem, title: "No reading in the last 10 minutes",
                                         detail: "Keep the phone near you, or scan the sensor.", fix: .openSensor))
            } else {
                items.append(BedtimeItem(id: "bluetooth", status: .ok, title: "Bluetooth connected", detail: "", fix: .none))
            }
        }

        if !input.runInBackground {
            items.append(BedtimeItem(id: "background", status: .problem, title: "Run in background is off",
                                     detail: "No alerts sound while the app is closed.", fix: .runInBackground))
        }

        if !input.notificationsAllowed {
            items.append(BedtimeItem(id: "notifications", status: .problem, title: "Notifications are off",
                                     detail: "Alerts can't show or sound while the app is closed.", fix: .notificationSettings))
        }

        if let minutes = input.missingDataMinutes {
            items.append(BedtimeItem(id: "missing", status: .ok, title: "No-data alert armed (\(minutes) min)", detail: "", fix: .none))
        } else {
            items.append(BedtimeItem(id: "missing", status: .warning, title: "No-data alert is off",
                                     detail: "You wouldn't hear it if readings stopped overnight.", fix: .missingDataAlert))
        }

        items.append(input.urgentLowSoundsThroughSilent
            ? BedtimeItem(id: "silent", status: .ok, title: "Urgent low sounds through Silent", detail: "", fix: .none)
            : BedtimeItem(id: "silent", status: .warning, title: "Urgent low follows Silent mode",
                          detail: "With the ring switch on silent, or in a Focus, it may not wake you.", fix: .urgentLowThroughSilent))

        if !input.isDemo, let end = input.sensorEndsAt {
            if end <= input.now {
                items.append(BedtimeItem(id: "sensor", status: .problem, title: "The sensor has ended",
                                         detail: "Start the next sensor: there are no readings tonight.", fix: .openSensor))
            } else if end < input.morning {
                items.append(BedtimeItem(id: "sensor", status: .problem, title: "Sensor ends at \(time(end))",
                                         detail: "Readings stop then. Start the next sensor before bed.", fix: .openSensor))
            } else {
                items.append(BedtimeItem(id: "sensor", status: .ok, title: "Sensor until \(time(end))", detail: "", fix: .none))
            }
        }

        if let expiry = input.buildExpiresAt {
            if expiry < input.morning {
                items.append(BedtimeItem(id: "build", status: .problem, title: "This app build expires at \(time(expiry))",
                                         detail: "Install the new build first: an expired app doesn't open or alert.", fix: .newBuild))
            } else {
                let days = Int(expiry.timeIntervalSince(input.now) / 86_400)
                items.append(BedtimeItem(id: "build", status: days < 2 ? .warning : .ok,
                                         title: days < 1 ? "App build expires tomorrow" : "App build valid \(days) day\(days == 1 ? "" : "s")",
                                         detail: days < 2 ? "Install the new build soon." : "", fix: days < 2 ? .newBuild : .none))
            }
        }

        // Stable order within each status, the urgent ones first.
        return items.enumerated()
            .sorted { $0.element.status != $1.element.status ? $0.element.status < $1.element.status : $0.offset < $1.offset }
            .map(\.element)
    }

    /// The end of tonight: the next `hour` o'clock after `now`.
    public static func morning(after now: Date, hour: Int = 7, calendar: Calendar = .autoupdatingCurrent) -> Date {
        calendar.nextDate(after: now, matching: DateComponents(hour: hour, minute: 0), matchingPolicy: .nextTime)
            ?? now.addingTimeInterval(9 * 3600)
    }

    /// Whether `now` falls in the evening window that starts an hour before `bedtimeMinutes`
    /// (minutes after midnight) and lasts until 4 AM.
    public static func isEvening(_ now: Date, bedtimeMinutes: Int, calendar: Calendar = .autoupdatingCurrent) -> Bool {
        let components = calendar.dateComponents([.hour, .minute], from: now)
        let minutes = (components.hour ?? 0) * 60 + (components.minute ?? 0)
        let start = bedtimeMinutes - 60
        return minutes >= start || minutes < 4 * 60
    }
}

/// Lows over recent nights (22:00 to 06:00), for the bedtime summary.
public struct NightLowSummary: Hashable, Sendable {
    public let nightsWithData: Int
    public let nightsWithLows: Int
    /// The hour (0...23) most lows started in, when there were any.
    public let typicalHour: Int?

    /// Counts the `nights` nights before `now` (the one in progress is left out). A night has a
    /// low when 3 or more readings are below 70 mg/dL; it has data with at least 2 hours of it.
    public static func make(readings: [GlucoseReading], now: Date, nights: Int = 7,
                            calendar: Calendar = .autoupdatingCurrent) -> NightLowSummary {
        var withData = 0
        var withLows = 0
        var startHours: [Int] = []
        let today6 = calendar.date(bySettingHour: 6, minute: 0, second: 0, of: now) ?? now
        let lastEnd = now >= today6 ? today6 : calendar.date(byAdding: .day, value: -1, to: today6) ?? today6
        for back in 0..<nights {
            guard let end = calendar.date(byAdding: .day, value: -back, to: lastEnd) else { continue }
            let start = end.addingTimeInterval(-8 * 3600)
            let night = readings.filter { $0.timestamp >= start && $0.timestamp < end }
            guard Set(night.map { Int($0.timestamp.timeIntervalSince(start) / 900) }).count >= 8 else { continue }
            withData += 1
            let lows = night.filter { $0.mgdL < 70 }.sorted { $0.timestamp < $1.timestamp }
            if lows.count >= 3, let first = lows.first {
                withLows += 1
                startHours.append(calendar.component(.hour, from: first.timestamp))
            }
        }
        let counts = Dictionary(grouping: startHours, by: { $0 }).mapValues(\.count)
        let typical = counts.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }?.key
        return NightLowSummary(nightsWithData: withData, nightsWithLows: withLows, typicalHour: typical)
    }
}
