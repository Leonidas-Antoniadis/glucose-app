import Foundation
import ActivityKit
import WidgetKit
import GlucoseCore

/// What the Live Activity shows besides the value: a sounding alert, the last hour and the
/// last dose and meal.
struct LiveActivityExtras: Equatable {
    var alert: ActivityAlert?
    var points: [Double]?
    var change15: Double?
    var lastFastUnits: Double?
    var lastFastAt: Date?
    var lastFoodAt: Date?
}

/// Keeps the home-screen widgets and the lock-screen Live Activity current.
@MainActor
final class SurfaceUpdater {
    private var lastWidgetReload = Date.distantPast
    private var lastZone: Int?
    private var activity: Activity<GlucoseActivityAttributes>?
    /// When the current Live Activity started: iOS ends one after 8 hours.
    private var activityStartedAt: Date?

    /// iOS allows a few dozen widget reloads a day while the app is in the background.
    static let backgroundReloadInterval: TimeInterval = 20 * 60

    func update(latest: GlucoseReading, arrow: TrendArrow, recent: [GlucoseReading], unit: GlucoseUnit,
                liveActivityEnabled: Bool, isDemo: Bool = false, isForeground: Bool = true,
                extras: LiveActivityExtras = LiveActivityExtras()) {
        // One point per 5 minutes is plenty for a widget sparkline; it always ends at the value shown.
        let points = ReadingPipeline.sparkline(recent).map { WidgetSnapshot.Point(date: $0.timestamp, mgdL: $0.mgdL) }
        WidgetSnapshot(mgdL: latest.mgdL, timestamp: latest.timestamp, arrow: arrow.symbol,
                       unitRaw: unit.rawValue, points: points, isDemo: isDemo).save()

        // Reloads while the app is open are free. In the background they come out of a daily budget,
        // so they're spaced out, except when glucose moves into a low range.
        let zone = GlucoseShared.zone(mgdL: latest.mgdL)
        let enteredLow = zone != lastZone && zone <= 1
        if isForeground || enteredLow || Date().timeIntervalSince(lastWidgetReload) > Self.backgroundReloadInterval {
            WidgetCenter.shared.reloadAllTimelines()
            lastWidgetReload = Date()
        }
        lastZone = zone

        if liveActivityEnabled {
            updateLiveActivity(state(latest: latest, arrow: arrow, unit: unit, isDemo: isDemo, extras: extras),
                               isForeground: isForeground)
        }
    }

    private func state(latest: GlucoseReading, arrow: TrendArrow, unit: GlucoseUnit, isDemo: Bool,
                       extras: LiveActivityExtras) -> GlucoseActivityAttributes.ContentState {
        GlucoseActivityAttributes.ContentState(
            mgdL: latest.mgdL, arrow: arrow.symbol, timestamp: latest.timestamp, unitRaw: unit.rawValue, isDemo: isDemo,
            alert: extras.alert, points: extras.points, change15: extras.change15,
            lastFastUnits: extras.lastFastUnits, lastFastAt: extras.lastFastAt, lastFoodAt: extras.lastFoodAt)
    }

    private func content(_ state: GlucoseActivityAttributes.ContentState) -> ActivityContent<GlucoseActivityAttributes.ContentState> {
        // Stale 10 minutes after the reading itself, not after the update.
        ActivityContent(state: state, staleDate: state.timestamp.addingTimeInterval(10 * 60))
    }

    private func updateLiveActivity(_ state: GlucoseActivityAttributes.ContentState, isForeground: Bool) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let all = Activity<GlucoseActivityAttributes>.activities
        // A stale activity can still be updated, and updating makes it active again.
        let live = all.filter { $0.activityState == .active || $0.activityState == .stale }
        if let current = live.first(where: { $0.id == activity?.id }) ?? live.first {
            activity = current
            Task { await current.update(content(state)) }
            // Only one card on the Lock Screen.
            for extra in live where extra.id != current.id {
                Task { await extra.end(nil, dismissalPolicy: .immediate) }
            }
        } else if isForeground {
            // Ended or dismissed cards (iOS ends them after 8 hours) leave the Lock Screen first.
            for old in all { Task { await old.end(nil, dismissalPolicy: .immediate) } }
            activity = try? Activity.request(attributes: GlucoseActivityAttributes(), content: content(state), pushType: nil)
            activityStartedAt = activity == nil ? nil : Date()
        } else {
            // Starting needs the app on screen. An ended card shouldn't keep showing an old value.
            for old in all where old.activityState == .ended || old.activityState == .dismissed {
                Task { await old.end(nil, dismissalPolicy: .immediate) }
            }
            activity = nil
        }
    }

    var liveActivitiesAllowed: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    /// Ends any current Live Activity and starts a fresh one. Only works while the app is in the foreground.
    func restartLiveActivity(latest: GlucoseReading, arrow: TrendArrow, unit: GlucoseUnit, isDemo: Bool = false,
                             extras: LiveActivityExtras = LiveActivityExtras()) {
        let newState = state(latest: latest, arrow: arrow, unit: unit, isDemo: isDemo, extras: extras)
        let old = Activity<GlucoseActivityAttributes>.activities
        activity = try? Activity.request(attributes: GlucoseActivityAttributes(), content: content(newState), pushType: nil)
        activityStartedAt = activity == nil ? nil : Date()
        for current in old {
            Task { await current.end(nil, dismissalPolicy: .immediate) }
        }
    }

    /// When the app comes to the foreground: starts a fresh Live Activity if there is none or the
    /// current one is close to the 8-hour limit, so it doesn't freeze or vanish overnight.
    func renewLiveActivityIfNeeded(latest: GlucoseReading?, arrow: TrendArrow, unit: GlucoseUnit, isDemo: Bool, enabled: Bool,
                                   extras: LiveActivityExtras = LiveActivityExtras()) {
        guard enabled, let latest, liveActivitiesAllowed else { return }
        let live = Activity<GlucoseActivityAttributes>.activities.filter { $0.activityState == .active || $0.activityState == .stale }
        let old = activityStartedAt.map { Date().timeIntervalSince($0) > 6 * 3600 } ?? true
        if live.isEmpty || old {
            restartLiveActivity(latest: latest, arrow: arrow, unit: unit, isDemo: isDemo, extras: extras)
        }
    }

    func endLiveActivity() {
        for current in Activity<GlucoseActivityAttributes>.activities {
            Task { await current.end(nil, dismissalPolicy: .immediate) }
        }
        activity = nil
        activityStartedAt = nil
    }

    /// Clears the widgets and the Live Activity, for example when the data source changes, so a
    /// demo value never stays on the Lock Screen as if it were real.
    func reset() {
        endLiveActivity()
        WidgetSnapshot.clear()
        WidgetCenter.shared.reloadAllTimelines()
        lastZone = nil
    }
}
