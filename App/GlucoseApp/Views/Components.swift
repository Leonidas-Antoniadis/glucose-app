import SwiftUI
import Charts
import GlucoseCore

enum RangeColor {
    static func color(for mgdL: Double) -> Color {
        switch mgdL {
        case ..<54: return .red
        case ..<70: return .orange
        case ...180: return .green
        case ...250: return .yellow
        default: return .orange
        }
    }
}

/// Glucose history with the 70-180 target band. Swipe sideways to go back in time; touch and hold,
/// then slide, to read past values together with nearby notes and fingersticks.
struct GlucoseChart: View {
    let readings: [GlucoseReading]
    let unit: GlucoseUnit
    var entries: [LogEntry] = []
    var fingersticks: [FingerstickEntry] = []
    /// Width of the visible window.
    var visibleHours: Double = 3

    @State private var selectedDate: Date?
    @State private var scrollPosition = Date.distantPast

    private var visibleSeconds: TimeInterval { visibleHours * 3600 }

    var body: some View {
        let start = readings.first?.timestamp ?? Date()
        let end = readings.last?.timestamp ?? Date()
        let maxValue = max(300, readings.map(\.mgdL).max() ?? 0)
        let topY = unit.fromMgdL(maxValue)

        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                Chart {
                    RectangleMark(
                        xStart: .value("Start", start),
                        xEnd: .value("End", end),
                        yStart: .value("Target low", unit.fromMgdL(70)),
                        yEnd: .value("Target high", unit.fromMgdL(180))
                    )
                    .foregroundStyle(.green.opacity(0.12))

                    ForEach(readings) { reading in
                        LineMark(
                            x: .value("Time", reading.timestamp),
                            y: .value("Glucose", unit.fromMgdL(reading.mgdL))
                        )
                        .interpolationMethod(.monotone)
                        .foregroundStyle(.primary)
                    }

                    ForEach(entries.filter { $0.date >= start && $0.date <= end }) { entry in
                        PointMark(x: .value("Time", entry.date), y: .value("Note", topY))
                            .symbol {
                                Image(systemName: entry.symbolName)
                                    .font(.caption2)
                                    .foregroundStyle(.blue)
                            }
                    }

                    ForEach(fingersticks.filter { $0.date >= start && $0.date <= end }) { stick in
                        PointMark(x: .value("Time", stick.date), y: .value("Fingerstick", unit.fromMgdL(stick.mgdL)))
                            .symbol {
                                Image(systemName: "drop.fill")
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                    }

                    if let selectedDate, let nearest = nearest(to: selectedDate) {
                        RuleMark(x: .value("Selected", nearest.timestamp))
                            .foregroundStyle(.gray.opacity(0.5))
                        PointMark(x: .value("Selected", nearest.timestamp), y: .value("Value", unit.fromMgdL(nearest.mgdL)))
                            .foregroundStyle(RangeColor.color(for: nearest.mgdL))
                            .symbolSize(80)
                            .annotation(position: .top, spacing: 8,
                                        overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                                SelectionCallout(reading: nearest, unit: unit,
                                                 notes: entriesNear(nearest.timestamp), stick: fingerstickNear(nearest.timestamp))
                            }
                    }
                }
                .chartYScale(domain: unit.fromMgdL(40)...topY)
                .chartScrollableAxes(.horizontal)
                .chartXVisibleDomain(length: visibleSeconds)
                .chartScrollPosition(x: $scrollPosition)
                .chartXSelection(value: $selectedDate)
                .accessibilityLabel("Glucose chart")

                if isScrolledBack(end: end) {
                    Button("Now", systemImage: "arrow.right.to.line") { jumpToNow(end: end) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .padding(4)
                }
            }
            Text("Swipe to go back in time. Touch and hold, then slide, to read past values.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .onAppear {
            jumpToNow(end: end)
            if ScreenshotMode.arguments.contains("-select") {
                selectedDate = end.addingTimeInterval(-50 * 60)
            }
        }
        .onChange(of: visibleHours) { jumpToNow(end: end) }
    }

    private func isScrolledBack(end: Date) -> Bool {
        scrollPosition < end.addingTimeInterval(-visibleSeconds - 10 * 60)
    }

    private func jumpToNow(end: Date) {
        scrollPosition = end.addingTimeInterval(-visibleSeconds)
    }

    private func nearest(to date: Date) -> GlucoseReading? {
        readings.min { abs($0.timestamp.timeIntervalSince(date)) < abs($1.timestamp.timeIntervalSince(date)) }
    }

    private func entriesNear(_ date: Date) -> [LogEntry] {
        entries.filter { abs($0.date.timeIntervalSince(date)) <= 15 * 60 }
    }

    private func fingerstickNear(_ date: Date) -> FingerstickEntry? {
        fingersticks.first { abs($0.date.timeIntervalSince(date)) <= 15 * 60 }
    }
}

struct SelectionCallout: View {
    let reading: GlucoseReading
    let unit: GlucoseUnit
    let notes: [LogEntry]
    let stick: FingerstickEntry?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(unit.format(mgdL: reading.mgdL, includeSymbol: true))
                .font(.callout.bold())
                .foregroundStyle(RangeColor.color(for: reading.mgdL))
            Text(reading.timestamp.formatted(.dateTime.weekday(.abbreviated).hour().minute()))
                .font(.caption2)
                .foregroundStyle(.secondary)
            if let stick {
                Label("Fingerstick \(unit.format(mgdL: stick.mgdL))", systemImage: "drop.fill").font(.caption2)
            }
            ForEach(notes) { note in
                Label(note.title, systemImage: note.symbolName).font(.caption2)
            }
        }
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}

struct MetricRow: View {
    let label: String
    let value: String
    var warning = false

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            if warning {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            Text(value).monospacedDigit().foregroundStyle(.secondary)
        }
    }
}

struct Banner: View {
    let systemImage: String
    let text: String
    var color: Color = .orange

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.subheadline)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
    }
}

extension GlucoseUnit {
    /// Parses user input in this unit into mg/dL.
    func parse(_ text: String) -> Double? {
        let normalized = text.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)
        guard let value = Double(normalized), value > 0 else { return nil }
        return toMgdL(value)
    }
}
