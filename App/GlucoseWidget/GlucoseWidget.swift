import WidgetKit
import SwiftUI
import Charts

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
            let state = context.state
            let stale = context.isStale || GlucoseShared.isStale(timestamp: state.timestamp, at: Date())
            HStack(alignment: .center, spacing: 12) {
                Text(state.formattedValue)
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .foregroundStyle(stale ? Color.secondary : WidgetColors.color(mgdL: state.mgdL))
                    .strikethrough(stale)
                Text(stale ? "old" : state.arrow).font(stale ? .headline : .largeTitle)
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(state.isDemo == true ? "Demo · \(GlucoseShared.unitSymbol(state.unitRaw))" : GlucoseShared.unitSymbol(state.unitRaw))
                        .font(.caption)
                    Text(state.timestamp, style: .relative).font(.caption).monospacedDigit()
                }
                .foregroundStyle(.secondary)
            }
            .padding()
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
                    HStack {
                        Text(state.isDemo == true ? "Demo · \(GlucoseShared.unitSymbol(state.unitRaw))" : GlucoseShared.unitSymbol(state.unitRaw))
                        Spacer()
                        Text(state.timestamp, style: .relative)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            } compactLeading: {
                Text(state.formattedValue)
                    .bold()
                    .foregroundStyle(color)
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
