import SwiftUI
import Charts
import GlucoseCore

struct ReportsView: View {
    @Environment(AppModel.self) private var model
    @State private var days: Double = 1

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Period", selection: $days) {
                        Text("24 h").tag(1.0)
                        Text("7 days").tag(7.0)
                        Text("14 days").tag(14.0)
                    }
                    .pickerStyle(.segmented)
                }

                if let stats = statistics {
                    Section("Time in ranges") {
                        TimeInRangeBar(ranges: stats.ranges)
                            .frame(height: 28)
                        RangeRow(label: "Very high (>250)", value: stats.ranges.veryHigh, color: .orange)
                        RangeRow(label: "High (181-250)", value: stats.ranges.high, color: .yellow)
                        RangeRow(label: "In range (70-180)", value: stats.ranges.inRange, color: .green)
                        RangeRow(label: "Low (54-69)", value: stats.ranges.low, color: .orange)
                        RangeRow(label: "Very low (<54)", value: stats.ranges.veryLow, color: .red)
                    }
                    Section("Glucose") {
                        MetricRow(label: "Mean", value: model.unit.format(mgdL: stats.meanMgdL, includeSymbol: true))
                        MetricRow(label: "GMI", value: String(format: "%.1f %%", stats.gmiPercent))
                        MetricRow(label: "Standard deviation",
                                  value: model.unit.format(mgdL: stats.standardDeviationMgdL, includeSymbol: true))
                        MetricRow(label: "CV (target ≤ 36%)", value: String(format: "%.1f %%", stats.coefficientOfVariation),
                                  warning: !stats.isCVStable)
                        MetricRow(label: "Data sufficiency", value: String(format: "%.0f %%", stats.dataSufficiency * 100),
                                  warning: !stats.hasSufficientData)
                    }
                    Section("Ambulatory Glucose Profile") {
                        AGPChart(profile: AmbulatoryGlucoseProfile(readings: periodReadings), unit: model.unit)
                            .frame(height: 220)
                        Text("Median line, 25-75% (dark) and 5-95% (light) bands by time of day.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("Not enough data yet.")
                }
            }
            .navigationTitle("Reports")
        }
    }

    private var period: DateInterval? {
        guard let end = model.latest?.timestamp else { return nil }
        return DateInterval(start: end.addingTimeInterval(-days * 86_400), end: end)
    }

    private var periodReadings: [GlucoseReading] {
        guard let period else { return [] }
        return model.readings.filter { period.contains($0.timestamp) }
    }

    private var statistics: GlucoseStatistics? {
        guard let period else { return nil }
        return GlucoseStatistics(readings: model.readings, period: period)
    }
}

struct TimeInRangeBar: View {
    let ranges: RangeBreakdown

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 1) {
                segment(ranges.veryLow, .red, proxy.size.width)
                segment(ranges.low, .orange, proxy.size.width)
                segment(ranges.inRange, .green, proxy.size.width)
                segment(ranges.high, .yellow, proxy.size.width)
                segment(ranges.veryHigh, .orange.opacity(0.7), proxy.size.width)
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
    let color: Color

    var body: some View {
        HStack {
            Circle().fill(color).frame(width: 10, height: 10)
            Text(label)
            Spacer()
            Text(String(format: "%.1f %%", value * 100)).monospacedDigit()
        }
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
            Text(value).monospacedDigit()
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
