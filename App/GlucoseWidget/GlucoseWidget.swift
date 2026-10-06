import WidgetKit
import SwiftUI
import Charts
import AppIntents

@main
struct GlucoseWidgetBundle: WidgetBundle {
    var body: some Widget {
        GlucoseWidget()
        GlucoseLiveActivity()
    }
}

struct GlucoseEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?

    /// Older than 10 minutes at the time this entry is shown, or dated in the future.
    var isStale: Bool {
        guard let snapshot else { return true }
        return GlucoseShared.isStale(timestamp: snapshot.timestamp, at: date)
    }
}

struct GlucoseProvider: TimelineProvider {
    func placeholder(in context: Context) -> GlucoseEntry {
        GlucoseEntry(date: Date(), snapshot: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (GlucoseEntry) -> Void) {
        completion(GlucoseEntry(date: Date(), snapshot: context.isPreview ? .placeholder : (WidgetSnapshot.load() ?? .placeholder)))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<GlucoseEntry>) -> Void) {
        // The app reloads timelines on new data; entries every 5 minutes keep the age and stale state honest.
        let snapshot = WidgetSnapshot.load()
        let now = Date()
        let entries = (0..<7).map { GlucoseEntry(date: now.addingTimeInterval(Double($0) * 300), snapshot: snapshot) }
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(30 * 60))))
    }
}

struct GlucoseWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "GlucoseWidget", provider: GlucoseProvider()) { entry in
            GlucoseWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Glucose")
        .description("Latest glucose value, trend and the last 3 hours.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

enum WidgetColors {
    static func color(mgdL: Double) -> Color {
        RangePalette.color(mgdL: mgdL)
    }
}

struct GlucoseWidgetView: View {
    let entry: GlucoseEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if let snapshot = entry.snapshot {
            let stale = entry.isStale
            let demo = snapshot.isDemo == true
            switch family {
            case .accessoryInline:
                // The line above the clock has no room for colour: an old value says "old" instead of an arrow.
                Text("\(demo ? "Demo " : "")\(snapshot.formattedValue) \(stale ? "old" : snapshot.arrow) \(snapshot.unitSymbol)")
            case .accessoryCircular:
                VStack(spacing: 0) {
                    Text(snapshot.formattedValue).font(.title3.bold()).minimumScaleFactor(0.6)
                        .strikethrough(stale)
                    Text(stale ? "old" : (demo ? "demo" : snapshot.arrow)).font(.caption)
                }
            case .accessoryRectangular:
                HStack {
                    VStack(alignment: .leading) {
                        Text("\(snapshot.formattedValue) \(stale ? "" : snapshot.arrow)")
                            .font(.title2.bold())
                            .strikethrough(stale)
                        Text(demo ? "Demo" : (stale ? "Old value" : "Now"))
                            .font(.caption2)
                        Text(snapshot.timestamp, style: .relative).font(.caption)
                    }
                    Spacer()
                }
            case .systemMedium:
                HStack(spacing: 12) {
                    valueStack(snapshot, stale: stale, demo: demo)
                    Sparkline(points: snapshot.points)
                }
            default:
                valueStack(snapshot, stale: stale, demo: demo)
            }
        } else {
            VStack(alignment: .leading) {
                Text("--").font(.largeTitle.bold())
                Text("Open the app").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func valueStack(_ snapshot: WidgetSnapshot, stale: Bool, demo: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(snapshot.formattedValue)
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .foregroundStyle(stale ? Color.secondary : WidgetColors.color(mgdL: snapshot.mgdL))
                    .strikethrough(stale)
                    .minimumScaleFactor(0.6)
                Text(stale ? "" : snapshot.arrow).font(.title2)
            }
            Text(demo ? "\(snapshot.unitSymbol) · DEMO" : snapshot.unitSymbol).font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text(snapshot.timestamp, style: .relative).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct Sparkline: View {
    let points: [WidgetSnapshot.Point]

    var body: some View {
        let start = points.first?.date ?? Date()
        let end = points.last?.date ?? Date()
        // Deep lows (down to LO, 39 mg/dL) stay inside the chart.
        let bottom = min(40, (points.map(\.mgdL).min() ?? 40) - 5)
        Chart {
            RectangleMark(xStart: .value("Start", start), xEnd: .value("End", end),
                          yStart: .value("Low", 70), yEnd: .value("High", 180))
                .foregroundStyle(.green.opacity(0.15))
            ForEach(points, id: \.date) { point in
                LineMark(x: .value("Time", point.date), y: .value("Glucose", point.mgdL))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(.primary)
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: bottom...max(250, points.map(\.mgdL).max() ?? 0))
        .chartPlotStyle { $0.clipped() }
    }
}

struct GlucoseLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: GlucoseActivityAttributes.self) { context in
            LiveActivityLockScreenView(state: context.state, isStale: context.isStale)
                .activitySystemActionForegroundColor(.primary)
        } dynamicIsland: { context in
            let state = context.state
            let stale = context.isStale || GlucoseShared.isStale(timestamp: state.timestamp, at: Date())
            let color = stale ? Color.secondary : WidgetColors.color(mgdL: state.mgdL)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Text(state.formattedValue)
                        .font(.system(size: 36, weight: .bold, design: .rounded))
                        .foregroundStyle(color)
                        .strikethrough(stale)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(stale ? "old" : state.arrow).font(stale ? .headline : .largeTitle)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        if let alert = state.alert {
                            AlertBannerText(alert: alert)
                                .font(.caption.bold())
                                .foregroundStyle(alert.isLow ? Color.red : Color.orange)
                        }
                        HStack {
                            Text(state.isDemo == true ? "Demo · \(GlucoseShared.unitSymbol(state.unitRaw))" : GlucoseShared.unitSymbol(state.unitRaw))
                            Spacer()
                            Text(state.timestamp, style: .relative)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        if let alert = state.alert, !alert.isSnoozed {
                            AlertButtons(alert: alert)
                        }
                    }
                }
            } compactLeading: {
                Text(state.formattedValue)
                    .bold()
                    .foregroundStyle(state.alert.map { $0.isLow ? Color.red : Color.orange } ?? color)
                    .strikethrough(stale)
            } compactTrailing: {
                Text(stale ? "old" : state.arrow)
            } minimal: {
                Text(state.formattedValue)
                    .font(.caption2.bold())
                    .foregroundStyle(color)
                    .strikethrough(stale)
            }
        }
    }
}

extension ActivityAlert {
    var isSnoozed: Bool { (snoozedUntil ?? .distantPast) > Date() }
}

/// "LOWER · since 3:05 AM", or with "snoozed until 3:35 AM".
struct AlertBannerText: View {
    let alert: ActivityAlert

    var body: some View {
        let since = alert.since.formatted(date: .omitted, time: .shortened)
        if let until = alert.snoozedUntil, alert.isSnoozed {
            Text("\(alert.name.uppercased()) · since \(since) · snoozed until \(until.formatted(date: .omitted, time: .shortened))")
        } else {
            Text("\(alert.name.uppercased()) · since \(since)")
        }
    }
}

/// Snooze, and Treating for a low. Both run in the app without opening it.
struct AlertButtons: View {
    let alert: ActivityAlert

    var body: some View {
        HStack(spacing: 10) {
            Button(intent: SnoozeAlertIntent(ruleID: alert.ruleID)) {
                Label("Snooze", systemImage: "bell.slash")
                    .frame(maxWidth: .infinity, minHeight: 36)
                    .background(Color.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            if alert.isLow {
                Button(intent: TreatingLowIntent(ruleID: alert.ruleID)) {
                    Label("Treating", systemImage: "drop.fill")
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .background(Color.orange.opacity(0.22), in: RoundedRectangle(cornerRadius: 12))
                        .foregroundStyle(Color.orange)
                }
                .buttonStyle(.plain)
            }
        }
        .font(.subheadline.weight(.semibold))
    }
}

/// The Lock Screen card. During an alert it gets a red (low) or orange (high) banner with the
/// rule name and since when, the last hour's shape, and Snooze and Treating.
struct LiveActivityLockScreenView: View {
    let state: GlucoseActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        let stale = isStale || GlucoseShared.isStale(timestamp: state.timestamp, at: Date())
        let valueColor = stale ? Color.secondary : WidgetColors.color(mgdL: state.mgdL)
        VStack(alignment: .leading, spacing: 0) {
            if let alert = state.alert {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    AlertBannerText(alert: alert)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .font(.caption.bold())
                .foregroundStyle(alert.isLow ? Color.red : Color.orange)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background((alert.isLow ? Color.red : Color.orange).opacity(0.18))
            }
            HStack(alignment: .center, spacing: 10) {
                Text(state.formattedValue)
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .foregroundStyle(valueColor)
                    .strikethrough(stale)
                Text(stale ? "old" : state.arrow)
                    .font(stale ? .headline : .largeTitle)
                    .foregroundStyle(valueColor)
                Spacer()
                if let points = state.points, points.count >= 2 {
                    LastHourLine(points: points, color: valueColor)
                        .frame(width: 110, height: 40)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            subline
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 2)
            if let alert = state.alert, !alert.isSnoozed {
                AlertButtons(alert: alert)
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                doses
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
            }
        }
        .padding(.bottom, 12)
    }

    /// "mg/dL · −9 in 15 min · 1 min ago"
    private var subline: Text {
        let unit = state.isDemo == true ? "Demo · \(GlucoseShared.unitSymbol(state.unitRaw))" : GlucoseShared.unitSymbol(state.unitRaw)
        var text = Text(unit)
        if let change = state.formattedChange {
            text = text + Text(" · \(change) in 15 min")
        }
        return text + Text(" · ") + Text(state.timestamp, style: .relative) + Text(" ago")
    }

    private var doses: some View {
        HStack(spacing: 14) {
            if let at = state.lastFastAt, let units = state.lastFastUnits {
                Text("Fast \(units.formatted(.number.precision(.fractionLength(0...1)))) U · ") + Text(at, style: .relative) + Text(" ago")
            }
            if let at = state.lastFoodAt {
                Text("Food · ") + Text(at, style: .relative) + Text(" ago")
            }
        }
    }
}

/// The last hour as a line, with the target range behind it.
struct LastHourLine: View {
    let points: [Double]
    let color: Color

    var body: some View {
        Canvas { context, size in
            let low = min(60, (points.min() ?? 60) - 10)
            let high = max(200, (points.max() ?? 200) + 10)
            func y(_ value: Double) -> CGFloat { size.height * (1 - (value - low) / (high - low)) }
            context.fill(Path(CGRect(x: 0, y: y(180), width: size.width, height: y(70) - y(180))),
                         with: .color(Color.green.opacity(0.14)))
            var line = Path()
            for (index, value) in points.enumerated() {
                let point = CGPoint(x: size.width * CGFloat(index) / CGFloat(max(points.count - 1, 1)), y: y(value))
                if index == 0 { line.move(to: point) } else { line.addLine(to: point) }
            }
            context.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            if let last = points.last {
                let center = CGPoint(x: size.width, y: y(last))
                context.fill(Path(ellipseIn: CGRect(x: center.x - 3.5, y: center.y - 3.5, width: 7, height: 7)), with: .color(color))
            }
        }
        .accessibilityLabel("Last hour")
    }
}
