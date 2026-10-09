import Foundation
import AVFoundation
import UIKit
import GlucoseCore

/// The bedtime readiness check: what could keep an alarm from being heard tonight.
extension AppModel {
    func bedtimeInputs(now: Date = Date()) -> BedtimeInputs {
        var input = BedtimeInputs(now: now, morning: BedtimeCheck.morning(after: now))
        input.mediaVolume = Self.freshMediaVolume()
        let device = UIDevice.current
        input.batteryLevel = device.batteryLevel >= 0 ? Double(device.batteryLevel) : nil
        input.isCharging = device.batteryState == .charging || device.batteryState == .full
        input.bluetoothOn = sensor.status != .bluetoothOff
        input.sensorConnected = latest.map { now.timeIntervalSince($0.timestamp) < 600 } ?? false
        input.isDemo = isDemo
        input.runInBackground = settings.runInBackground
        input.notificationsAllowed = notificationProblem == nil
        input.notificationProblem = notificationProblem
        input.missingDataMinutes = settings.missingData.isEnabled ? settings.missingData.minutes : nil
        input.hasAllDayUrgentLow = !settings.ruleSet.urgentLowRules.isEmpty
        input.urgentLowSoundsThroughSilent = settings.ruleSet.urgentLowRules.contains { $0.isCritical && $0.sound != .silent }
        input.sensorEndsAt = sensor.record?.expiresAt
        input.buildExpiresAt = signatureExpiry
        return input
    }

    func bedtimeItems(now: Date = Date()) -> [BedtimeItem] {
        BedtimeCheck.items(bedtimeInputs(now: now)) { $0.formatted(.dateTime.weekday(.abbreviated).hour().minute()) }
    }

    /// "Tonight: 96 ↘ now · …": the value and trend, the last slow insulin and recent night lows.
    func tonightSummary(now: Date = Date()) -> [String] {
        var parts: [String] = []
        if let latest, now.timeIntervalSince(latest.timestamp) < 15 * 60 {
            let arrow = trendArrow(at: now)
            parts.append("\(unit.formatReading(mgdL: latest.mgdL)) \(arrow == .unknown ? "" : arrow.symbol) now"
                .replacingOccurrences(of: "  ", with: " "))
            if arrow != .unknown, arrow != .stable, let projected = Trend.projected(readings(lastHours: 0.5), minutesAhead: 20) {
                parts.append("about \(unit.format(mgdL: max(40, projected))) in 20 min if this trend continues")
            }
        }
        if let slow = QuickLog.lastInsulin(.long, in: logbook), now.timeIntervalSince(slow.date) < 18 * 3600 {
            parts.append("Slow insulin \(LogEntry.format(slow.units)) U at \(slow.date.formatted(date: .omitted, time: .shortened))")
        }
        let nights = NightLowSummary.make(readings: readings, now: now)
        if nights.nightsWithLows > 0 {
            var text = "Lows on \(nights.nightsWithLows) of the last \(nights.nightsWithData) nights"
            if let hour = nights.typicalHour {
                let time = Calendar.autoupdatingCurrent.date(bySettingHour: hour, minute: 0, second: 0, of: now) ?? now
                text += ", most around \(time.formatted(.dateTime.hour()))"
            }
            parts.append(text)
        } else if nights.nightsWithData >= 3 {
            parts.append("No lows in the last \(nights.nightsWithData) nights")
        }
        return parts
    }

    /// The media volume, 0...1. `outputVolume` can be stale while the app's audio session is
    /// inactive, so with nothing playing a session that mixes with other audio (it doesn't stop
    /// music) is activated first. Once active it stays current, so it's switched on again only
    /// after an alarm or a preview changed it, or once a minute, not on every read (Home and the
    /// bedtime card read it every 5 seconds).
    static func freshMediaVolume() -> Double {
        let session = AVAudioSession.sharedInstance()
        if !AlarmPlayer.isActive, SoundPreviewPlayer.shared.playing == nil,
           session.category != .ambient || Date().timeIntervalSince(volumeSessionActivatedAt) > 60 {
            try? session.setCategory(.ambient, options: [.mixWithOthers])
            try? session.setActive(true)
            volumeSessionActivatedAt = Date()
        }
        return Double(session.outputVolume)
    }

    private static var volumeSessionActivatedAt = Date.distantPast

    // MARK: When to show it

    private static let dismissedKey = "bedtimeDismissedNight"
    private static let notifiedKey = "bedtimeNotifiedNight"

    /// The night a time belongs to: the day its evening window started, so a bedtime after
    /// midnight and a Done tapped at 01:00 still count for the same night.
    func nightKey(_ date: Date) -> String {
        let window = BedtimeCheck.eveningWindow(containing: date, bedtimeMinutes: settings.bedtimeMinutes)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: window?.start ?? date)
    }

    /// From an hour before bedtime until 4 AM (or 4 hours for a late bedtime), unless dismissed
    /// for tonight.
    func showsBedtimeCard(at now: Date) -> Bool {
        settings.bedtimeCheck
            && BedtimeCheck.isEvening(now, bedtimeMinutes: settings.bedtimeMinutes)
            && UserDefaults.standard.string(forKey: Self.dismissedKey) != nightKey(now)
    }

    func dismissBedtimeCard(at now: Date = Date()) {
        UserDefaults.standard.set(nightKey(now), forKey: Self.dismissedKey)
    }

    /// Schedules tonight's (or tomorrow's) bedtime reminder. It fires only if no check runs
    /// before it: no readings arriving is exactly what the check can't see from inside the app.
    func rescheduleBedtimeReminder(after date: Date = Date()) {
        guard settings.bedtimeCheck, !isDemo, settings.dataSource == .libre else {
            notifications.cancelBedtimeReminder()
            return
        }
        let parts = DateComponents(hour: settings.bedtimeMinutes / 60, minute: settings.bedtimeMinutes % 60)
        guard let next = Calendar.autoupdatingCurrent.nextDate(after: date, matching: parts, matchingPolicy: .nextTime) else { return }
        notifications.scheduleBedtimeReminder(at: next)
    }

    /// Called with each new reading. From 15 minutes before bedtime until 2 hours after, the app
    /// can check for itself: the scheduled reminder moves to tomorrow, and with the app closed a
    /// notification lists what needs fixing (nothing is sent when all is well). With the app open
    /// the Home card shows the same.
    func bedtimeCheckpoint(isActive: Bool, now: Date = Date()) {
        guard settings.bedtimeCheck, !isDemo else { return }
        let components = Calendar.autoupdatingCurrent.dateComponents([.hour, .minute], from: now)
        let minutes = (components.hour ?? 0) * 60 + (components.minute ?? 0)
        guard (minutes - (settings.bedtimeMinutes - 15) + 2 * 1440) % 1440 < 135 else { return }
        // Tonight is covered: the reminder moves past tonight's bedtime.
        rescheduleBedtimeReminder(after: now.addingTimeInterval(3 * 3600))
        guard !isActive else { return }
        let night = nightKey(now)
        guard UserDefaults.standard.string(forKey: Self.notifiedKey) != night,
              UserDefaults.standard.string(forKey: Self.dismissedKey) != night else { return }
        let problems = bedtimeItems(now: now).filter { $0.status == .problem }
        guard !problems.isEmpty else { return }
        UserDefaults.standard.set(night, forKey: Self.notifiedKey)
        notifications.post(title: "Before you sleep",
                           body: problems.map(\.title).joined(separator: " · ") + ". Open Glucose to fix it.")
    }
}
