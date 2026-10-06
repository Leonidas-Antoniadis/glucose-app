import SwiftUI
import Charts
import GlucoseCore

enum RangeColor {
    static func color(for mgdL: Double) -> Color {
        RangePalette.color(mgdL: mgdL)
    }
}

/// Glucose history with the 70-180 target band. Swipe sideways to go back in time; touch and hold,
/// then slide, to read past values together with nearby notes and fingersticks.
struct GlucoseChart: View {
    let readings: [GlucoseReading]
    let unit: GlucoseUnit
    var entries: [LogEntry] = []
    var fingersticks: [FingerstickEntry] = []
    /// Alert thresholds drawn as dashed lines.
    var alertLines: [AlertRule] = []
    /// Width of the visible window.
    var visibleHours: Double = 3

    @State private var selectedDate: Date?
    @State private var scrollPosition = Date.distantPast
    @Environment(\.scenePhase) private var scenePhase

    private struct LinePoint: Identifiable {
        let id: String
        let date: Date
        let value: Double
        let segment: Int
    }

    private var visibleSeconds: TimeInterval { visibleHours * 3600 }

    var body: some View {
        let start = readings.first?.timestamp ?? Date()
        let lastReading = readings.last?.timestamp ?? Date()
        // Entries logged after the newest reading (readings stopped) are still shown.
        let end = max(lastReading, Date())
        let maxValue = max(300, readings.map(\.mgdL).max() ?? 0)
        // Deep lows (down to LO, 39 mg/dL) stay inside the chart instead of running off its floor.
        let minValue = (readings.map(\.mgdL).min() ?? 40) < 40 ? 30.0 : 40.0
        // Notes sit on this line; the axis goes a little higher so their icons aren't cut in half.
        let markerY = unit.fromMgdL(maxValue)
        let topY = unit.fromMgdL(maxValue * 1.08)
        let line = zip(readings, ReadingPipeline.segmentIndices(readings)).map { reading, segment in
            LinePoint(id: reading.id, date: reading.timestamp, value: unit.fromMgdL(reading.mgdL), segment: segment)
        }

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

                    ForEach(alertLines.filter { (minValue...maxValue).contains($0.thresholdMgdL) }) { rule in
                        RuleMark(y: .value("Alert", unit.fromMgdL(rule.thresholdMgdL)))
                            .foregroundStyle(rule.direction == .low ? Color.red : Color.orange)
                            .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    }

                    // One line per stretch without gaps: missing hours stay empty instead of being
                    // bridged by a smooth line that could hide a low.
                    ForEach(line) { point in
                        LineMark(
                            x: .value("Time", point.date),
                            y: .value("Glucose", point.value),
                            series: .value("Segment", point.segment)
                        )
                        .interpolationMethod(.monotone)
                        .foregroundStyle(.primary)
                    }

                    ForEach(entries.filter { $0.date >= start && $0.date <= end }) { entry in
                        PointMark(x: .value("Time", entry.date), y: .value("Note", markerY))
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
                .chartYScale(domain: unit.fromMgdL(minValue)...topY)
                .chartXAxis {
                    AxisMarks(values: .stride(by: .hour, count: axisStrideHours)) { value in
                        let date = value.as(Date.self)
                        AxisGridLine()
                        AxisTick()
                        AxisValueLabel(collisionResolution: .greedy) {
                            Text(date.map(axisLabel(for:)) ?? "")
                                .font(.caption2)
                                .fontWeight(date.map(isMidnight) == true ? .semibold : .regular)
                        }
                    }
                }
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
                selectedDate = lastReading.addingTimeInterval(-50 * 60)
            }
        }
        .onChange(of: visibleHours) { jumpToNow(end: end) }
        // Follow new readings while the window shows "now"; leave it where it is if scrolled back.
        .onChange(of: readings.last?.timestamp) { oldEnd, _ in
            let previousEnd = max(oldEnd ?? .distantPast, Date().addingTimeInterval(-90))
            if scrollPosition >= previousEnd.addingTimeInterval(-visibleSeconds - 3 * 60) {
                jumpToNow(end: end)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            // Coming back to the app (the view stays alive in the tab bar) shows the latest hours.
            if phase == .active { jumpToNow(end: end) }
        }
    }

    /// Hours between time labels, so a window always shows 3-4 short labels.
    private var axisStrideHours: Int {
        switch visibleHours {
        case ...3: return 1
        case ...6: return 2
        case ...12: return 3
        default: return 6
        }
    }

    private func isMidnight(_ date: Date) -> Bool {
        Calendar.current.component(.hour, from: date) == 0
    }

    /// "4:00 PM" (or "16:00"), and the day at midnight ("Tue 6") so days stay clear when scrolling back.
    private func axisLabel(for date: Date) -> String {
        isMidnight(date)
            ? date.formatted(.dateTime.weekday(.abbreviated).day())
            : date.formatted(date: .omitted, time: .shortened)
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
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                // The range color sits in a dot, so the value stays readable (yellow text on white isn't).
                Circle()
                    .fill(RangeColor.color(for: reading.mgdL))
                    .frame(width: 8, height: 8)
                Text(unit.formatReading(mgdL: reading.mgdL, includeSymbol: true))
                    .font(.callout.bold())
                    .foregroundStyle(.primary)
            }
            Text(reading.timestamp.formatted(.dateTime.weekday(.abbreviated).hour().minute()))
                .font(.caption2)
                .foregroundStyle(.secondary)
            if let stick {
                Label("Fingerstick \(unit.format(mgdL: stick.mgdL))", systemImage: "drop.fill")
                    .font(.caption2)
                    .foregroundStyle(.primary)
            }
            ForEach(notes) { note in
                Label(note.title, systemImage: note.symbolName)
                    .font(.caption2)
                    .foregroundStyle(.primary)
            }
        }
        .padding(8)
        // Solid card: the green target band and the line behind it don't show through.
        .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(uiColor: .separator), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
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

/// A glucose value chosen from a menu in 5 mg/dL steps.
struct GlucoseValuePicker: View {
    let title: String
    @Binding var mgdL: Double
    let range: ClosedRange<Double>
    let unit: GlucoseUnit

    var body: some View {
        Picker(title, selection: $mgdL) {
            ForEach(options, id: \.self) { value in
                Text(unit.format(mgdL: value, includeSymbol: true)).tag(value)
            }
        }
        .pickerStyle(.menu)
    }

    /// Every 5 mg/dL in the range, plus the current value if it isn't on a step.
    private var options: [Double] {
        var values = Array(stride(from: (range.lowerBound / 5).rounded(.up) * 5, through: range.upperBound, by: 5))
        if !values.contains(mgdL) {
            values.append(mgdL)
            values.sort()
        }
        return values
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
