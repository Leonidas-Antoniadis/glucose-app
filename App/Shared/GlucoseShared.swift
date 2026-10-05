import Foundation
import ActivityKit

/// Compiled into both the app and the widget extension.
enum GlucoseShared {
    static let appGroup = "group.com.leonidasantoniadis.glucoseapp"

    static func format(mgdL: Double, unitRaw: String) -> String {
        unitRaw == "mmolL" ? String(format: "%.1f", mgdL / 18.016) : String(Int(mgdL.rounded()))
    }

    static func unitSymbol(_ unitRaw: String) -> String {
        unitRaw == "mmolL" ? "mmol/L" : "mg/dL"
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

    private static let key = "latestSnapshot"

    static func load() -> WidgetSnapshot? {
        guard let data = UserDefaults(suiteName: GlucoseShared.appGroup)?.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults(suiteName: GlucoseShared.appGroup)?.set(data, forKey: Self.key)
    }

    var formattedValue: String { GlucoseShared.format(mgdL: mgdL, unitRaw: unitRaw) }
    var unitSymbol: String { GlucoseShared.unitSymbol(unitRaw) }

    static let placeholder = WidgetSnapshot(
        mgdL: 112, timestamp: Date(), arrow: "→", unitRaw: "mgdL",
        points: (0..<36).map { Point(date: Date().addingTimeInterval(Double($0 - 36) * 300), mgdL: 110 + sin(Double($0) / 5) * 25) }
    )
}

struct GlucoseActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var mgdL: Double
        var arrow: String
        var timestamp: Date
        var unitRaw: String

        var formattedValue: String { GlucoseShared.format(mgdL: mgdL, unitRaw: unitRaw) }
    }
}
