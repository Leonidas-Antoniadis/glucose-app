import Foundation
import AVFoundation
import UIKit
import GlucoseCore

/// The bedtime readiness check: what could keep an alarm from being heard tonight.
extension AppModel {
    func bedtimeInputs(now: Date = Date()) -> BedtimeInputs {
        var input = BedtimeInputs(now: now, morning: BedtimeCheck.morning(after: now))
        input.mediaVolume = Double(AVAudioSession.sharedInstance().outputVolume)
        let device = UIDevice.current
        input.batteryLevel = device.batteryLevel >= 0 ? Double(device.batteryLevel) : nil
        input.isCharging = device.batteryState == .charging || device.batteryState == .full
        input.bluetoothOn = sensor.status != .bluetoothOff
        input.sensorConnected = latest.map { now.timeIntervalSince($0.timestamp) < 600 } ?? false
        input.isDemo = isDemo
        input.runInBackground = settings.runInBackground
        input.notificationsAllowed = notificationProblem == nil
        input.missingDataMinutes = settings.missingData.isEnabled ? settings.missingData.minutes : nil
        input.urgentLowSoundsThroughSilent = settings.ruleSet.urgentLowRules.contains { $0.isCritical }
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

    // MARK: When to show it

    private static let dismissedKey = "bedtimeDismissedNight"
    private static let notifiedKey = "bedtimeNotifiedNight"

    /// The night a time belongs to: until 4 AM it's still the evening before.
    static func nightKey(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date.addingTimeInterval(-4 * 3600))
    }

    /// From an hour before bedtime until 4 AM, unless dismissed for tonight.
    func showsBedtimeCard(at now: Date) -> Bool {
        settings.bedtimeCheck
            && BedtimeCheck.isEvening(now, bedtimeMinutes: settings.bedtimeMinutes)
            && UserDefaults.standard.string(forKey: Self.dismissedKey) != Self.nightKey(now)
    }

    func dismissBedtimeCard(at now: Date = Date()) {
        UserDefaults.standard.set(Self.nightKey(now), forKey: Self.dismissedKey)
    }

    /// At bedtime, with the app closed, a notification lists what needs fixing. Nothing is sent
    /// when all is well. Once a night, within two hours after bedtime.
    func notifyBedtimeProblemsIfNeeded(now: Date = Date()) {
        guard settings.bedtimeCheck, !isDemo else { return }
        let components = Calendar.autoupdatingCurrent.dateComponents([.hour, .minute], from: now)
        let minutes = (components.hour ?? 0) * 60 + (components.minute ?? 0)
        guard (minutes - settings.bedtimeMinutes + 1440) % 1440 < 120 else { return }
        let night = Self.nightKey(now)
        guard UserDefaults.standard.string(forKey: Self.notifiedKey) != night,
              UserDefaults.standard.string(forKey: Self.dismissedKey) != night else { return }
        UserDefaults.standard.set(night, forKey: Self.notifiedKey)
        let problems = bedtimeItems(now: now).filter { $0.status == .problem }
        guard !problems.isEmpty else { return }
        notifications.post(title: "Before you sleep",
                           body: problems.map(\.title).joined(separator: " · ") + ". Open Glucose to fix it.")
    }
}
