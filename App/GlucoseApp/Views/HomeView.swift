import SwiftUI
import GlucoseCore
import LibreProtocol

struct HomeView: View {
    @Environment(AppModel.self) private var model
    @State private var hours: Double = 3
    @State private var logged: LoggedToast?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Re-checked every 30 seconds: when readings stop, nothing else changes, and the
                    // value must still turn grey and the "No reading since" banner appear.
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        VStack(alignment: .leading, spacing: 16) {
                            StatusBanners(now: context.date)
                            CurrentValueCard(now: context.date)
                        }
                    }
                    HomeQuickLog(logged: $logged)
                    Picker("Chart window", selection: $hours) {
                        ForEach([3.0, 6, 12, 24], id: \.self) { Text("\(Int($0)) h").tag($0) }
                    }
                    .pickerStyle(.segmented)
                    GlucoseChart(readings: model.chartReadings, unit: model.unit, entries: model.logbook,
                                 fingersticks: model.fingersticks,
                                 alertLines: model.settings.ruleSet.rules.filter { $0.isEnabled && $0.isCritical },
                                 visibleHours: hours)
                        .frame(height: 300)
                    CriticalAlertsCard()
                    RecentAlertsList()
                }
                .padding()
            }
            .overlay(alignment: .bottom) {
                if let logged {
                    UndoToast(toast: logged) {
                        model.deleteLogEntries(logged.entryIDs)
                        withAnimation { self.logged = nil }
                    }
                    .padding()
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task(id: logged.id) {
                        do {
                            try await Task.sleep(for: .seconds(6))
                            withAnimation { self.logged = nil }
                        } catch {}
                    }
                }
            }
            .sensoryFeedback(.success, trigger: logged) { _, new in new != nil }
            .navigationTitle("Glucose")
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
    @Environment(\.openURL) private var openURL
    var now = Date()

    var body: some View {
        VStack(spacing: 8) {
            if model.isDemo {
                Banner(systemImage: "play.circle", text: "Demo data. Pair a sensor in Settings → Data source.", color: .blue)
            }
            if let problem = model.notificationProblem {
                ActionBanner(systemImage: "bell.slash.fill", text: problem, color: .red,
                             actions: [("Open Settings", { openNotificationSettings(openURL) })])
            }
            if let expiry = model.signatureExpiry, expiry.timeIntervalSinceNow < 2 * 86_400 {
                Banner(systemImage: "clock.badge.exclamationmark",
                       text: "This app build expires \(expiry.formatted(.relative(presentation: .named))). "
                           + (ProvisioningProfile.isTestFlight ? "Install the newest build from TestFlight." : "Re-install it with Sideloadly."),
                       color: .red)
            }
            if !model.isDemo {
                if let record = sensor.record, now < record.warmUpEndsAt {
                    // A new sensor gives no readings for its first hour: nothing to scan or pair again.
                    Banner(systemImage: "hourglass",
                           text: "New sensor warming up. Readings start at \(record.warmUpEndsAt.formatted(date: .omitted, time: .shortened)).",
                           color: .blue)
                } else if model.isStale(at: now), let latest = model.latest, sensor.record != nil {
                    ActionBanner(
                        systemImage: "antenna.radiowaves.left.and.right.slash",
                        text: noDataText(since: latest.timestamp),
                        color: .red,
                        actions: [
                            ("Scan sensor", { _ = Task { await sensor.scanHistory() } }),
                            ("Pair again", { _ = Task { await sensor.pair() } }),
                        ]
                    )
                } else if let gap = model.readingGap(at: now) {
                    let span = "\(gap.start.formatted(date: .omitted, time: .shortened))–\(gap.end.formatted(date: .omitted, time: .shortened))"
                    if model.canFillWithNFC(gap) {
                        ActionBanner(systemImage: "chart.line.downtrend.xyaxis",
                                     text: "Missing readings \(span). Scan the sensor to fill the gap from its 8-hour memory.",
                                     color: .orange,
                                     actions: [("Scan sensor", { _ = Task { await sensor.scanHistory() } })])
                    } else if model.isGapBetweenSensors(gap) {
                        Banner(systemImage: "chart.line.downtrend.xyaxis",
                               text: "No readings \(span), between sensors and during warm-up.")
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
                ActionBanner(systemImage: "xmark.octagon", text: error, color: .red,
                             actions: [("Dismiss", { model.lastError = nil })])
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
    var now = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let latest = model.latest {
                let stale = model.isStale(at: now)
                let arrow = model.trendArrow(at: now)
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(model.unit.formatReading(mgdL: latest.mgdL))
                        .font(.system(size: 72, weight: .bold, design: .rounded))
                        .foregroundStyle(stale ? Color.secondary : RangeColor.color(for: latest.mgdL))
                        .strikethrough(stale)
                        .contentTransition(.numericText())
                    Text(arrow.symbol)
                        .font(.system(size: 48, weight: .semibold))
                        .accessibilityLabel(arrow.spokenName)
                    Text(model.unit.symbol)
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
                if model.isDemo, model.settings.demoSpeed == .fast {
                    // 60x demo readings are dated ahead of the clock, so an age would be nonsense.
                    Text("Simulated, 60x speed")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Text(latest.timestamp, style: .relative)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    + Text(" ago")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                SensorSummaryRow(now: now)
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
    var now = Date()

    var body: some View {
        HStack {
            if model.isDemo {
                Label("Demo sensor", systemImage: "play.circle")
            } else if let record = sensor.record {
                Label(sensor.status.title, systemImage: "sensor.tag.radiowaves.forward")
                Spacer()
                if record.expiresAt > now {
                    Text("ends in ") + Text(record.expiresAt, style: .relative)
                } else {
                    Text("ended ") + Text(record.expiresAt, style: .relative) + Text(" ago")
                }
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
            let events = Array(model.recentEvents.prefix(10))
            ForEach(Array(events.enumerated()), id: \.offset) { index, event in
                // Snooze only on the newest row of an alert that is sounding now: on an old row it
                // would silence the next episode.
                let isNewestOfRule = !events.prefix(index).contains { $0.ruleID == event.ruleID }
                HStack {
                    Image(systemName: event.direction == .low ? "arrow.down.circle.fill" : "arrow.up.circle.fill")
                        .foregroundStyle(event.direction == .low ? .red : .orange)
                    VStack(alignment: .leading) {
                        Text("\(event.ruleName): \(model.unit.formatReading(mgdL: event.valueMgdL, includeSymbol: true))")
                        Text(event.date, style: .time).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if isNewestOfRule, model.isAlertSounding(event.ruleID) {
                        Button("Snooze") { model.acknowledge(ruleID: event.ruleID) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
            }
        }
    }
}
