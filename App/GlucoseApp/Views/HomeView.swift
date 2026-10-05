import SwiftUI
import GlucoseCore
import LibreProtocol

struct HomeView: View {
    @Environment(AppModel.self) private var model
    @State private var hours: Double = 3
    @State private var quickAdd: QuickLogKind?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    StatusBanners()
                    CurrentValueCard()
                    QuickAddBar { quickAdd = $0 }
                    Picker("Chart window", selection: $hours) {
                        ForEach([3.0, 6, 12, 24], id: \.self) { Text("\(Int($0)) h").tag($0) }
                    }
                    .pickerStyle(.segmented)
                    GlucoseChart(readings: model.chartReadings, unit: model.unit, entries: model.logbook,
                                 fingersticks: model.fingersticks, visibleHours: hours)
                        .frame(height: 300)
                    RecentAlertsList()
                }
                .padding()
            }
            .navigationTitle("Glucose")
            .sheet(item: $quickAdd) { kind in AddLogEntryView(kind: kind) }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        SensorView()
                    } label: {
                        Label("Sensor", systemImage: "sensor.tag.radiowaves.forward")
                    }
                }
            }
        }
    }
}

struct StatusBanners: View {
    @Environment(AppModel.self) private var model
    @Environment(SensorConnection.self) private var sensor

    var body: some View {
        VStack(spacing: 8) {
            if model.isDemo {
                Banner(systemImage: "play.circle", text: "Demo data. Pair a sensor in Settings → Data source.", color: .blue)
            }
            if let expiry = model.signatureExpiry, expiry.timeIntervalSinceNow < 2 * 86_400 {
                Banner(systemImage: "clock.badge.exclamationmark",
                       text: "This app build expires \(expiry.formatted(.relative(presentation: .named))). Re-install it with Sideloadly.",
                       color: .red)
            }
            if !model.isDemo {
                if model.isStale, let latest = model.latest, sensor.record != nil {
                    ActionBanner(
                        systemImage: "antenna.radiowaves.left.and.right.slash",
                        text: noDataText(since: latest.timestamp),
                        color: .red,
                        actions: [
                            ("Scan sensor", { _ = Task { await sensor.scanHistory() } }),
                            ("Pair again", { _ = Task { await sensor.pair() } }),
                        ]
                    )
                } else if let gap = model.readingGap {
                    let span = "\(gap.start.formatted(date: .omitted, time: .shortened))–\(gap.end.formatted(date: .omitted, time: .shortened))"
                    if model.canFillWithNFC(gap) {
                        ActionBanner(systemImage: "chart.line.downtrend.xyaxis",
                                     text: "Missing readings \(span). Scan the sensor to fill the gap from its 8-hour memory.",
                                     color: .orange,
                                     actions: [("Scan sensor", { _ = Task { await sensor.scanHistory() } })])
                    } else {
                        Banner(systemImage: "chart.line.downtrend.xyaxis",
                               text: "Missing readings \(span). The sensor only keeps 8 hours, so this gap can't be filled.")
                    }
                }
                if let record = sensor.record {
                    if !record.calibration.isCalibrated {
                        Banner(systemImage: "drop", text: "Values are uncalibrated estimates. Add a fingerstick to calibrate.")
                    } else if record.calibration.needsCalibration(now: Date()) {
                        Banner(systemImage: "drop", text: "Last calibration is over a day old. Add a fingerstick.")
                    }
                } else {
                    Banner(systemImage: "sensor.tag.radiowaves.forward", text: "No sensor paired. Tap the sensor icon to pair.")
                }
            }
            if let error = model.lastError {
                Banner(systemImage: "xmark.octagon", text: error, color: .red)
            }
        }
    }

    /// Explains the likely causes when readings stop.
    private func noDataText(since date: Date) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        switch sensor.status {
        case .bluetoothOff:
            return "No reading since \(time): Bluetooth is off. Turn it on to reconnect."
        case .ended:
            return "No reading since \(time): the sensor has ended."
        default:
            return "No reading since \(time). Keep the phone within a few meters of the sensor. If you scanned the sensor with LibreLink or the reader, it now sends to that app: tap Pair again to take it back. Scan to fill the gap."
        }
    }
}

/// A banner with buttons.
struct ActionBanner: View {
    let systemImage: String
    let text: String
    var color: Color = .orange
    let actions: [(String, () -> Void)]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(text, systemImage: systemImage)
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                ForEach(Array(actions.enumerated()), id: \.offset) { _, action in
                    Button(action.0, action: action.1)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(color)
                }
            }
        }
        .padding(12)
        .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct CurrentValueCard: View {
    @Environment(AppModel.self) private var model
    @Environment(SensorConnection.self) private var sensor

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let latest = model.latest {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(model.unit.format(mgdL: latest.mgdL))
                        .font(.system(size: 72, weight: .bold, design: .rounded))
                        .foregroundStyle(model.isStale ? Color.secondary : RangeColor.color(for: latest.mgdL))
                        .strikethrough(model.isStale)
                        .contentTransition(.numericText())
                    Text(model.trendArrow.symbol)
                        .font(.system(size: 48, weight: .semibold))
                        .accessibilityLabel("Trend \(String(describing: model.trendArrow))")
                    Text(model.unit.symbol)
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
                Text(latest.timestamp, style: .relative)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                + Text(" ago")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                SensorSummaryRow()
            } else {
                ContentUnavailableView("No readings yet", systemImage: "drop",
                                       description: Text(model.isDemo ? "The demo starts in a moment." : "Waiting for the sensor."))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

struct SensorSummaryRow: View {
    @Environment(AppModel.self) private var model
    @Environment(SensorConnection.self) private var sensor

    var body: some View {
        HStack {
            if model.isDemo {
                Label("Demo sensor", systemImage: "play.circle")
            } else if let record = sensor.record {
                Label(sensor.status.title, systemImage: "sensor.tag.radiowaves.forward")
                Spacer()
                Text("ends ") + Text(record.expiresAt, style: .relative)
            } else {
                Label("No sensor", systemImage: "sensor.tag.radiowaves.forward")
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
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
                    Button("Snooze") { model.acknowledge(ruleID: event.ruleID) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
        }
    }
}
