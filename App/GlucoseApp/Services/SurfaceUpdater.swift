import Foundation
import ActivityKit
import WidgetKit
import GlucoseCore

/// Keeps the home-screen widgets and the lock-screen Live Activity current.
@MainActor
final class SurfaceUpdater {
    private var lastWidgetReload = Date.distantPast
    private var lastZone: Int?
    private var activity: Activity<GlucoseActivityAttributes>?

    func update(latest: GlucoseReading, arrow: TrendArrow, recent: [GlucoseReading], unit: GlucoseUnit, liveActivityEnabled: Bool) {
        // One point per 5 minutes is plenty for a widget sparkline.
        var lastBucket = Date.distantPast
        let points = recent.compactMap { reading -> WidgetSnapshot.Point? in
            guard reading.timestamp.timeIntervalSince(lastBucket) >= 5 * 60 else { return nil }
            lastBucket = reading.timestamp
            return WidgetSnapshot.Point(date: reading.timestamp, mgdL: reading.mgdL)
        }
        WidgetSnapshot(mgdL: latest.mgdL, timestamp: latest.timestamp, arrow: arrow.symbol,
                       unitRaw: unit.rawValue, points: points).save()

        // iOS limits widget reloads, so reload every 5 minutes or when the range changes.
        let zone = GlucoseShared.zone(mgdL: latest.mgdL)
        if Date().timeIntervalSince(lastWidgetReload) > 5 * 60 || zone != lastZone {
            WidgetCenter.shared.reloadAllTimelines()
            lastWidgetReload = Date()
            lastZone = zone
        }

        if liveActivityEnabled {
            updateLiveActivity(GlucoseActivityAttributes.ContentState(
                mgdL: latest.mgdL, arrow: arrow.symbol, timestamp: latest.timestamp, unitRaw: unit.rawValue))
        }
    }

    private func updateLiveActivity(_ state: GlucoseActivityAttributes.ContentState) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(10 * 60))
        if let current = activity ?? Activity<GlucoseActivityAttributes>.activities.first, current.activityState == .active {
            activity = current
            Task { await current.update(content) }
        } else {
            // Starting is only allowed while the app is in the foreground; later updates work in the background.
            activity = try? Activity.request(attributes: GlucoseActivityAttributes(), content: content, pushType: nil)
        }
    }

    func endLiveActivity() {
        for current in Activity<GlucoseActivityAttributes>.activities {
            Task { await current.end(nil, dismissalPolicy: .immediate) }
        }
        activity = nil
    }
}
