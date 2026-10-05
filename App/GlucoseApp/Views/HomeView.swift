import SwiftUI
import Charts
import GlucoseCore

struct HomeView: View {
    @Environment(AppModel.self) private var model
    @State private var hours: Double = 3

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    CurrentValueCard()
                    Picker("Chart range", selection: $hours) {
                        ForEach([3.0, 6, 12, 24], id: \.self) { Text("\(Int($0)) h").tag($0) }
                    }
                    .pickerStyle(.segmented)
                    GlucoseChart(readings: model.readings(lastHours: hours), unit: model.unit)
                        .frame(height: 260)
                    RecentAlertsList()
                }
                .padding()
            }
            .navigationTitle("Glucose")
        }
    }
}

struct CurrentValueCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let latest = model.latest {
                let arrow = Trend.arrow(forRate: Trend.ratePerMinute(model.readings(lastHours: 0.5)))
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(model.unit.format(mgdL: latest.mgdL))
                        .font(.system(size: 72, weight: .bold, design: .rounded))
                        .foregroundStyle(RangeColor.color(for: latest.mgdL))
                        .contentTransition(.numericText())
                    Text(arrow.symbol)
                        .font(.system(size: 48, weight: .semibold))
                        .accessibilityLabel(String(describing: arrow))
                    Text(model.unit.symbol)
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
                Text(latest.timestamp, style: .relative)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                SensorStatusRow()
            } else {
                ProgressView("Waiting for the first reading…")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

struct SensorStatusRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let expires = SensorLifecycle.expires(startedAt: model.sensorStartedAt)
        HStack {
            Label("Simulated sensor", systemImage: "sensor.tag.radiowaves.forward")
            Spacer()
            Text("ends ") + Text(expires, style: .relative)
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }
}

struct GlucoseChart: View {
    let readings: [GlucoseReading]
    let unit: GlucoseUnit

    var body: some View {
        let start = readings.first?.timestamp ?? Date()
        let end = readings.last?.timestamp ?? Date()
        let maxValue = max(300, readings.map(\.mgdL).max() ?? 0)

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
        }
        .chartYScale(domain: unit.fromMgdL(40)...unit.fromMgdL(maxValue))
        .accessibilityLabel("Glucose chart")
    }
}

struct RecentAlertsList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recent alerts").font(.headline)
            if model.recentEvents.isEmpty {
                Text("No alerts yet.").foregroundStyle(.secondary)
            }
            ForEach(Array(model.recentEvents.prefix(10).enumerated()), id: \.offset) { _, event in
                HStack {
                    Image(systemName: event.direction == .low ? "arrow.down.circle.fill" : "arrow.up.circle.fill")
                        .foregroundStyle(event.direction == .low ? .red : .orange)
                    VStack(alignment: .leading) {
                        Text("\(event.ruleName): \(model.unit.format(mgdL: event.valueMgdL, includeSymbol: true))")
                        Text(event.date, style: .time).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Snooze") { model.acknowledge(event) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
        }
    }
}

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
