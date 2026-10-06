import SwiftUI
import Charts
import GlucoseCore

struct ReportsView: View {
    @Environment(AppModel.self) private var model
    @State private var days: Double = 14
    @State private var pdfURL: URL?
    @State private var csvURL: URL?

    var body: some View {
        let period = currentPeriod
        let readings = period.map { model.archivedReadings(in: $0) } ?? []
        let stats = period.flatMap { GlucoseStatistics(readings: readings, period: $0) }

        NavigationStack {
            List {
                Section {
                    Picker("Period", selection: $days) {
                        Text("1 d").tag(1.0)
                        Text("7 d").tag(7.0)
                        Text("14 d").tag(14.0)
                        Text("30 d").tag(30.0)
                        Text("90 d").tag(90.0)
                    }
                    .pickerStyle(.segmented)
                }

                if let stats, let period {
                    let u = model.unit
                    Section("Time in ranges") {
                        TimeInRangeBar(ranges: stats.ranges).frame(height: 28)
                        RangeRow(label: "Very high (>\(u.format(mgdL: 250)))", value: stats.ranges.veryHigh, target: "< 5%",
                                 color: RangePalette.color(zone: 4))
                        RangeRow(label: "High (\(u.format(mgdL: 181))-\(u.format(mgdL: 250)))", value: stats.ranges.high, target: nil,
                                 color: RangePalette.color(zone: 3))
                        RangeRow(label: "In range (\(u.format(mgdL: 70))-\(u.format(mgdL: 180)))", value: stats.ranges.inRange, target: "> 70%",
                                 color: RangePalette.color(zone: 2))
                        RangeRow(label: "Low (\(u.format(mgdL: 54))-\(u.format(mgdL: 69)))", value: stats.ranges.low, target: nil,
                                 color: RangePalette.color(zone: 1))
                        RangeRow(label: "Very low (<\(u.format(mgdL: 54)))", value: stats.ranges.veryLow, target: "< 1%",
                                 color: RangePalette.color(zone: 0))
                    }
                    Section("Glucose") {
                        MetricRow(label: "Mean", value: model.unit.format(mgdL: stats.meanMgdL, includeSymbol: true))
                        MetricRow(label: "GMI", value: String(format: "%.1f %%", stats.gmiPercent))
                        MetricRow(label: "Standard deviation", value: model.unit.format(mgdL: stats.standardDeviationMgdL, includeSymbol: true))
                        MetricRow(label: "CV (target ≤ 36%)", value: String(format: "%.1f %%", stats.coefficientOfVariation),
                                  warning: !stats.isCVStable)
                        MetricRow(label: "Sensor data", value: String(format: "%.0f %%", stats.dataSufficiency * 100),
                                  warning: !stats.hasSufficientData)
                    }
                    let split = DailyPatterns.dayNight(readings, period: period)
                    Section("Day and night") {
                        if let day = split.day {
                            MetricRow(label: "Day (06-22): in range", value: String(format: "%.0f %%", day.ranges.inRange * 100))
                            MetricRow(label: "Day: mean", value: model.unit.format(mgdL: day.meanMgdL, includeSymbol: true))
                        }
                        if let night = split.night {
                            MetricRow(label: "Night (22-06): in range", value: String(format: "%.0f %%", night.ranges.inRange * 100))
                            MetricRow(label: "Night: below \(model.unit.format(mgdL: 70))", value: String(format: "%.1f %%", night.ranges.belowRange * 100),
                                      warning: night.ranges.belowRange > 0.04)
                        }
                    }
                    Section {
                        AGPChart(profile: AmbulatoryGlucoseProfile(readings: readings), unit: model.unit)
                            .frame(height: 220)
                    } header: {
                        Text("Ambulatory Glucose Profile")
                    } footer: {
                        Text("Median line with 25-75% (dark) and 5-95% (light) bands by time of day.")
                    }
                    if days <= 14 {
                        Section("Daily overlay") {
                            DailyOverlayChart(days: DailyPatterns.overlay(readings), unit: model.unit)
                                .frame(height: 220)
                        }
                    }
                    Section {
                        Button("Create PDF report", systemImage: "doc.richtext") {
                            pdfURL = ReportExporter.pdf(stats: stats, readings: readings, period: period, unit: model.unit,
                                                        calibrated: model.sensor.record?.calibration.isCalibrated == true)
                        }
                        if let pdfURL {
                            ShareLink(item: pdfURL) { Label("Share PDF", systemImage: "square.and.arrow.up") }
                        }
                        Button("Create CSV (readings, notes, fingersticks)", systemImage: "tablecells") {
                            csvURL = ReportExporter.csvBundle(readings: readings, logbook: model.logbook, fingersticks: model.fingersticks)
                        }
                        if let csvURL {
                            ShareLink(item: csvURL) { Label("Share CSV", systemImage: "square.and.arrow.up") }
                        }
                    } header: {
                        Text("Export")
                    } footer: {
                        Text("Files are created on the phone and shared only where you send them.")
                    }
                } else {
                    ContentUnavailableView("Not enough data yet", systemImage: "chart.bar")
                }
            }
            .navigationTitle("Reports")
            .onChange(of: days) {
                pdfURL = nil
                csvURL = nil
            }
        }
    }

    /// Ends at the newest reading, or now if there's none in memory (more than 14 days without a
    /// sensor), so the 30 and 90-day reports still come from the archive.
    private var currentPeriod: DateInterval? {
        let end = model.latest?.timestamp ?? Date()
        return DateInterval(start: end.addingTimeInterval(-days * 86_400), end: end)
    }
}

struct TimeInRangeBar: View {
    let ranges: RangeBreakdown

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 1) {
                segment(ranges.veryLow, RangePalette.color(zone: 0), proxy.size.width)
                segment(ranges.low, RangePalette.color(zone: 1), proxy.size.width)
                segment(ranges.inRange, RangePalette.color(zone: 2), proxy.size.width)
                segment(ranges.high, RangePalette.color(zone: 3), proxy.size.width)
                segment(ranges.veryHigh, RangePalette.color(zone: 4), proxy.size.width)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityLabel(String(format: "%.0f percent in range", ranges.inRange * 100))
    }

    private func segment(_ fraction: Double, _ color: Color, _ width: CGFloat) -> some View {
        color.frame(width: max(0, width * fraction))
    }
}

struct RangeRow: View {
    let label: String
    let value: Double
    let target: String?
    let color: Color

    var body: some View {
        HStack {
            Circle().fill(color).frame(width: 10, height: 10)
            Text(label)
            Spacer()
            if let target {
                Text(target).font(.caption).foregroundStyle(.secondary)
            }
            Text(String(format: "%.1f %%", value * 100)).monospacedDigit()
        }
    }
}

struct AGPChart: View {
    let profile: AmbulatoryGlucoseProfile
    let unit: GlucoseUnit

    var body: some View {
        Chart {
            ForEach(profile.bins, id: \.minuteOfDay) { bin in
                AreaMark(
                    x: .value("Time", Double(bin.minuteOfDay) / 60),
                    yStart: .value("5%", unit.fromMgdL(bin.p5)),
                    yEnd: .value("95%", unit.fromMgdL(bin.p95)),
                    series: .value("Band", "5-95")
                )
                .foregroundStyle(.blue.opacity(0.15))
            }
            ForEach(profile.bins, id: \.minuteOfDay) { bin in
                AreaMark(
                    x: .value("Time", Double(bin.minuteOfDay) / 60),
                    yStart: .value("25%", unit.fromMgdL(bin.p25)),
                    yEnd: .value("75%", unit.fromMgdL(bin.p75)),
                    series: .value("Band", "25-75")
                )
                .foregroundStyle(.blue.opacity(0.35))
            }
            ForEach(profile.bins, id: \.minuteOfDay) { bin in
                LineMark(
                    x: .value("Time", Double(bin.minuteOfDay) / 60),
                    y: .value("Median", unit.fromMgdL(bin.median))
                )
                .foregroundStyle(.blue)
            }
        }
        .chartXScale(domain: 0...24)
        .chartXAxis {
            AxisMarks(values: [0.0, 6, 12, 18, 24]) { value in
                AxisGridLine()
                AxisValueLabel { Text("\(Int(value.as(Double.self) ?? 0)):00") }
            }
        }
    }
}

struct DailyOverlayChart: View {
    let days: [DailyPatterns.DaySeries]
    let unit: GlucoseUnit

    var body: some View {
        Chart {
            RectangleMark(xStart: .value("Start", 0.0), xEnd: .value("End", 24.0),
                          yStart: .value("Low", unit.fromMgdL(70)), yEnd: .value("High", unit.fromMgdL(180)))
                .foregroundStyle(.green.opacity(0.1))
            ForEach(days) { day in
                ForEach(day.points, id: \.minuteOfDay) { point in
                    LineMark(
                        x: .value("Time", Double(point.minuteOfDay) / 60),
                        y: .value("Glucose", unit.fromMgdL(point.mgdL)),
                        series: .value("Day", day.day)
                    )
                    .foregroundStyle(.blue.opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                }
            }
        }
        .chartXScale(domain: 0...24)
        .chartXAxis {
            AxisMarks(values: [0.0, 6, 12, 18, 24]) { value in
                AxisGridLine()
                AxisValueLabel { Text("\(Int(value.as(Double.self) ?? 0)):00") }
            }
        }
    }
}
