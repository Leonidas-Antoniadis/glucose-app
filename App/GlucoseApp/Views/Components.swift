import SwiftUI
import Charts
import GlucoseCore

enum RangeColor {
    static func color(for mgdL: Double) -> Color {
        RangePalette.color(mgdL: mgdL)
    }
}

/// Glucose history with the 70-180 target band. Swipe sideways to go back in time; touch and hold,
/// then slide, to read past values together with nearby notes and fingersticks. Tap a logged item's
/// icon to see what it was, when, and glucose then and now.
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
    /// The tapped icon group whose details are shown.
    @State private var openMarker: String?
    @Environment(\.scenePhase) private var scenePhase

    private struct LinePoint: Identifiable {
        let id: String
        let date: Date
        let value: Double
        let segment: Int
    }

    /// Logged items (or fingersticks) close enough on screen to share one tap target.
    private struct MarkerGroup: Identifiable {
        let id: String
        let date: Date
        let point: CGPoint
        var entries: [LogEntry] = []
        var sticks: [FingerstickEntry] = []
    }

    /// Size of an icon's tap target, in points.
    private static let markerTarget: CGFloat = 32

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
                // Tap targets over the visible icons only, so swiping and touch-and-hold work everywhere else.
                .chartOverlay { proxy in
                    GeometryReader { geometry in
                        if let plotFrame = proxy.plotFrame {
                            let plot = geometry[plotFrame]
                            ForEach(markerGroups(proxy: proxy, plot: plot, markerY: markerY)) { group in
                                markerButton(group)
                            }
                        }
                    }
                }
                .accessibilityLabel("Glucose chart")
            }
            // Under the chart, so it never covers the axis labels or the note icons.
            HStack(alignment: .center) {
                Text("Tap an icon to see what you logged. Swipe to go back in time; touch and hold, then slide, to read past values.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if isScrolledBack(end: end) {
                    Spacer(minLength: 8)
                    Button("Now", systemImage: "arrow.right.to.line") { jumpToNow(end: end) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
        }
        .onAppear {
            jumpToNow(end: end)
            if ScreenshotMode.arguments.contains("-select") {
                selectedDate = lastReading.addingTimeInterval(-50 * 60)
            }
            if ScreenshotMode.arguments.contains("-marker") {
                // After the first layout, so the icon's tap target exists to anchor the details.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    openMarker = entries.max { $0.date < $1.date }?.id.uuidString
                }
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

    /// The icons in the visible window and where they are on screen. Icons closer than a
    /// fingertip share one target, which opens all of them.
    private func markerGroups(proxy: ChartProxy, plot: CGRect, markerY: Double) -> [MarkerGroup] {
        let visible = scrollPosition.addingTimeInterval(-60)...scrollPosition.addingTimeInterval(visibleSeconds + 60)
        func location(_ date: Date, _ value: Double) -> CGPoint? {
            guard visible.contains(date), let x = proxy.position(forX: date), let y = proxy.position(forY: value) else { return nil }
            return CGPoint(x: plot.minX + x, y: plot.minY + y)
        }
        var groups: [MarkerGroup] = []
        func add(_ date: Date, at point: CGPoint, id: String, _ fill: (inout MarkerGroup) -> Void) {
            if let index = groups.lastIndex(where: {
                abs($0.point.x - point.x) < Self.markerTarget && abs($0.point.y - point.y) < Self.markerTarget
            }) {
                fill(&groups[index])
            } else {
                var group = MarkerGroup(id: id, date: date, point: point)
                fill(&group)
                groups.append(group)
            }
        }
        for entry in entries.sorted(by: { $0.date < $1.date }) {
            if let point = location(entry.date, markerY) {
                add(entry.date, at: point, id: entry.id.uuidString) { $0.entries.append(entry) }
            }
        }
        for stick in fingersticks.sorted(by: { $0.date < $1.date }) {
            if let point = location(stick.date, unit.fromMgdL(stick.mgdL)) {
                add(stick.date, at: point, id: stick.id.uuidString) { $0.sticks.append(stick) }
            }
        }
        return groups
    }

    private func markerButton(_ group: MarkerGroup) -> some View {
        Button {
            openMarker = group.id
        } label: {
            Color.clear
                .frame(width: Self.markerTarget, height: Self.markerTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel((group.entries.map(\.title)
            + group.sticks.map { "Fingerstick \(unit.format(mgdL: $0.mgdL, includeSymbol: true))" }).joined(separator: ", "))
        .accessibilityValue(group.date.formatted(date: .omitted, time: .shortened))
        // Before `position`, so the details point at the icon rather than the middle of the chart.
        .popover(isPresented: Binding(
            get: { openMarker == group.id },
            set: { if !$0, openMarker == group.id { openMarker = nil } }
        )) {
            MarkerDetails(entries: group.entries, sticks: group.sticks, unit: unit,
                          then: reading(near: group.date), latest: readings.last)
                .presentationCompactAdaptation(.popover)
        }
        .position(group.point)
    }

    /// The reading closest to a logged item, if there is one within 10 minutes.
    private func reading(near date: Date) -> GlucoseReading? {
        guard let match = nearest(to: date), abs(match.timestamp.timeIntervalSince(date)) <= 10 * 60 else { return nil }
        return match
    }
}

/// What was logged at a tapped icon, and how glucose went from then to now.
struct MarkerDetails: View {
    let entries: [LogEntry]
    let sticks: [FingerstickEntry]
    let unit: GlucoseUnit
    let then: GlucoseReading?
    let latest: GlucoseReading?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(entries) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    Label(entry.title, systemImage: entry.symbolName)
                        .font(.subheadline.weight(.semibold))
                    Text(Self.when(entry.date))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !entry.text.isEmpty {
                        Text(entry.text).font(.caption)
                    }
                }
            }
            ForEach(sticks) { stick in
                VStack(alignment: .leading, spacing: 2) {
                    Label("Fingerstick \(unit.format(mgdL: stick.mgdL, includeSymbol: true))", systemImage: "drop.fill")
                        .font(.subheadline.weight(.semibold))
                    Text(Self.when(stick.date))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let then {
                Divider()
                VStack(alignment: .leading, spacing: 2) {
                    Text("Glucose then: \(unit.formatReading(mgdL: then.mgdL, includeSymbol: true))")
                    if let latest, latest.timestamp.timeIntervalSince(then.timestamp) >= 5 * 60 {
                        Text("\(latestLabel(latest)): \(unit.formatReading(mgdL: latest.mgdL, includeSymbol: true)) (\(change(latest.mgdL - then.mgdL)))")
                    }
                }
                .font(.caption)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(14)
        // A set width: popovers size to their content, and long notes wrap instead of widening it.
        .frame(width: 260, alignment: .leading)
    }

    /// "4:35 PM · 15m ago", with the weekday when it wasn't today.
    static func when(_ date: Date) -> String {
        let time = Calendar.current.isDateInToday(date)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        return "\(time) · \(LastLoggedTiles.ago(date, now: Date()))"
    }

    /// "Now" while readings are current; otherwise the time of the last one.
    private func latestLabel(_ reading: GlucoseReading) -> String {
        Date().timeIntervalSince(reading.timestamp) < 15 * 60
            ? "Now"
            : "Latest (\(reading.timestamp.formatted(date: .omitted, time: .shortened)))"
    }

    private func change(_ mgdL: Double) -> String {
        (mgdL < 0 ? "−" : "+") + unit.format(mgdL: abs(mgdL)) + " since"
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
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(RangePalette.warningText)
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

/// A glucose value chosen from a menu: 5 mg/dL steps, or in mmol/L 0.1 steps (0.5 above 10), so
/// round values like 3.0, 3.5 and 4.0 mmol/L can be picked.
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

    /// The steps in the range, plus the current value if it isn't on a step.
    private var options: [Double] {
        var values: [Double]
        switch unit {
        case .mgdL:
            values = Array(stride(from: (range.lowerBound / 5).rounded(.up) * 5, through: range.upperBound, by: 5))
        case .mmolL:
            let low = (unit.fromMgdL(range.lowerBound) * 10).rounded(.up) / 10
            let high = (unit.fromMgdL(range.upperBound) * 10).rounded(.down) / 10
            let fine = stride(from: low, through: min(high, 9.95), by: 0.1).map { ($0 * 10).rounded() / 10 }
            let coarse = high >= 10 ? Array(stride(from: max(10, (low * 2).rounded(.up) / 2), through: high, by: 0.5)) : []
            values = (fine + coarse).map { unit.toMgdL($0) }
        }
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
        // Whole mg/dL in mmol/L: 10.0 mmol/L is 180, not 180.16, which would count as above range.
        return self == .mmolL ? toMgdL(value).rounded() : toMgdL(value)
    }
}
