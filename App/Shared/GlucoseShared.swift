import Foundation
import ActivityKit
import SwiftUI
import UIKit

/// Compiled into both the app and the widget extension.
enum GlucoseShared {
    static let appGroup = "group.com.leonidasantoniadis.glucoseapp"

    /// Same rules as `GlucoseUnit.formatReading`: LO at 39 mg/dL or below, HI at 501 or above.
    static func format(mgdL: Double, unitRaw: String) -> String {
        if mgdL <= 39 { return "LO" }
        if mgdL >= 501 { return "HI" }
        return unitRaw == "mmolL" ? String(format: "%.1f", mgdL / 18.016) : String(Int(mgdL.rounded()))
    }

    static func unitSymbol(_ unitRaw: String) -> String {
        unitRaw == "mmolL" ? "mmol/L" : "mg/dL"
    }

    /// What VoiceOver says for a widget or Live Activity value: "115 mg/dL, rising", with
    /// "old value" or "demo" when that applies, instead of arrow glyph names.
    static func spokenValue(_ value: String, unitRaw: String, arrow: String, stale: Bool, demo: Bool) -> String {
        if value == "•••" { return "Glucose value hidden" }
        let arrows = ["↓": "falling quickly", "↘": "falling", "→": "steady", "↗": "rising", "↑": "rising quickly"]
        var parts = [value == "LO" || value == "HI" ? value : "\(value) \(unitSymbol(unitRaw))"]
        if stale {
            parts.append("old value")
        } else if let trend = arrows[arrow] {
            parts.append(trend)
        }
        if demo { parts.append("demo") }
        return parts.joined(separator: ", ")
    }

    /// 0 very low, 1 low, 2 in range, 3 high, 4 very high.
    static func zone(mgdL: Double) -> Int {
        switch mgdL {
        case ..<54: return 0
        case ..<70: return 1
        case ...180: return 2
        case ...250: return 3
        default: return 4
        }
    }

    /// A value is stale when it's older than 10 minutes, or dated in the future (a clock change,
    /// or the 60x demo), which an age check alone would show as current forever.
    static func isStale(timestamp: Date, at date: Date) -> Bool {
        date.timeIntervalSince(timestamp) > 10 * 60 || timestamp.timeIntervalSince(date) > 2 * 60
    }
}

/// Range colors for the app and the widgets. Each range has its own hue (low and very high used
/// to share one orange), darker in light mode so a large number stays readable on a light
/// background (yellow wasn't), brighter in dark mode.
enum RangePalette {
    static func color(zone: Int) -> Color {
        switch zone {
        case 0: return adaptive(light: (0.73, 0.04, 0.12), dark: (1.00, 0.27, 0.23))   // very low: deep red
        case 1: return adaptive(light: (0.89, 0.30, 0.25), dark: (1.00, 0.55, 0.50))   // low: coral red
        case 2: return adaptive(light: (0.12, 0.55, 0.24), dark: (0.19, 0.82, 0.35))   // in range: green
        case 3: return adaptive(light: (0.66, 0.47, 0.00), dark: (1.00, 0.84, 0.04))   // high: amber / yellow
        default: return adaptive(light: (0.78, 0.33, 0.00), dark: (1.00, 0.62, 0.04))  // very high: orange
        }
    }

    static func color(mgdL: Double) -> Color {
        color(zone: GlucoseShared.zone(mgdL: mgdL))
    }

    /// Warning text (orange): dark enough to read on white and on a pale orange tint.
    static var warningText: Color { adaptive(light: (0.70, 0.31, 0.00), dark: (1.00, 0.62, 0.04)) }

    /// A color with its own light and dark values: darker in light mode so text stays readable.
    static func adaptive(light: (Double, Double, Double), dark: (Double, Double, Double)) -> Color {
        Color(UIColor { traits in
            let rgb = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
        })
    }
}

/// The latest value and a short history, written by the app for widgets.
struct WidgetSnapshot: Codable, Hashable {
    struct Point: Codable, Hashable {
        var date: Date
        var mgdL: Double
    }

    var mgdL: Double
    var timestamp: Date
    var arrow: String
    var unitRaw: String
    var points: [Point]
    /// Simulated by the demo, so the widgets can say so.
    var isDemo: Bool? = nil
    /// "Hide values on Lock Screen" is on: Lock Screen widgets show no value.
    var hidesValueOnLockScreen: Bool? = nil

    private static let legacyKey = "latestSnapshot"

    /// A file in the shared container's Caches folder, which iCloud and computer backups skip.
    /// (It used to sit in the shared UserDefaults, which are backed up.)
    private static var fileURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: GlucoseShared.appGroup)?
            .appendingPathComponent("Library/Caches", isDirectory: true)
            .appendingPathComponent("widget-snapshot.json")
    }

    static func load() -> WidgetSnapshot? {
        if let url = fileURL, let data = try? Data(contentsOf: url) {
            return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
        }
        guard let data = UserDefaults(suiteName: GlucoseShared.appGroup)?.data(forKey: legacyKey) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self), var url = Self.fileURL else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard (try? data.write(to: url, options: .atomic)) != nil else { return }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        UserDefaults(suiteName: GlucoseShared.appGroup)?.removeObject(forKey: Self.legacyKey)
    }

    /// Removes the saved value, so widgets show "Open the app" instead of an old or demo value.
    static func clear() {
        if let url = fileURL { try? FileManager.default.removeItem(at: url) }
        UserDefaults(suiteName: GlucoseShared.appGroup)?.removeObject(forKey: legacyKey)
    }

    var formattedValue: String { GlucoseShared.format(mgdL: mgdL, unitRaw: unitRaw) }
    /// For Lock Screen widgets: dots with "Hide values on Lock Screen" on.
    var lockScreenValue: String { hidesValueOnLockScreen == true ? "•••" : formattedValue }
    var lockScreenArrow: String { hidesValueOnLockScreen == true ? "" : arrow }
    var unitSymbol: String { GlucoseShared.unitSymbol(unitRaw) }

    static let placeholder = WidgetSnapshot(
        mgdL: 112, timestamp: Date(), arrow: "→", unitRaw: "mgdL",
        points: (0..<36).map { Point(date: Date().addingTimeInterval(Double($0 - 36) * 300), mgdL: 110 + sin(Double($0) / 5) * 25) }
    )
}

/// An alert that is sounding (or snoozed and not over yet), shown on the Live Activity.
struct ActivityAlert: Codable, Hashable {
    var name: String
    var ruleID: String
    var isLow: Bool
    /// When glucose first went past the threshold in this episode.
    var since: Date
    var snoozedUntil: Date?
}

struct GlucoseActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var mgdL: Double
        var arrow: String
        var timestamp: Date
        var unitRaw: String
        /// Simulated by the demo.
        var isDemo: Bool? = nil
        /// Set during an alert: the card turns red (low) or orange (high) with Snooze and Treating.
        var alert: ActivityAlert? = nil
        /// The last hour, one value per 5 minutes, oldest first, in mg/dL.
        var points: [Double]? = nil
        /// Change over the last 15 minutes, in mg/dL.
        var change15: Double? = nil
        /// "Hide values on Lock Screen" is on: the card shows that there is an alert, not the value.
        var hidesValue: Bool? = nil

        var formattedValue: String { GlucoseShared.format(mgdL: mgdL, unitRaw: unitRaw) }
        /// What the card shows: the value, or dots with "Hide values on Lock Screen" on.
        var shownValue: String { hidesValue == true ? "•••" : formattedValue }
        var shownArrow: String { hidesValue == true ? "" : arrow }

        /// "−9", "+0.5" or "±0" in the display unit.
        var formattedChange: String? {
            guard let change15, hidesValue != true else { return nil }
            // Not `format`: that turns anything at or below 39 into "LO", and a change is small.
            let size = unitRaw == "mmolL" ? String(format: "%.1f", abs(change15) / 18.016) : String(Int(abs(change15).rounded()))
            if Double(size) == 0 { return "±0" }
            return (change15 < 0 ? "−" : "+") + size
        }
    }
}
