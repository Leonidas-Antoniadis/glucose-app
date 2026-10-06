import SwiftUI
import GlucoseCore
import LibreProtocol

/// "Day 9 of 15" with a strip of the days: data captured, calibrations and the error that day.
struct SensorWearSection: View {
    @Environment(AppModel.self) private var model
    @State private var days: [SensorWearDay] = []

    var body: some View {
        if let context = model.wearContext {
            let now = max(Date(), model.latest?.timestamp ?? Date())
            let total = Double(context.lifetimeDays) * 86_400
            let elapsed = min(max(now.timeIntervalSince(context.activatedAt), 0), total)
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Day \(min(context.day(at: now), context.lifetimeDays)) of \(context.lifetimeDays)").font(.headline)
                        + Text(remainingText(context, now: now)).foregroundColor(.secondary)
                    ProgressView(value: elapsed, total: total)
                        .tint(context.expiresAt.timeIntervalSince(now) < 86_400 ? .orange : .accentColor)
                    Text("Ends \(context.expiresAt.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute()))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !days.isEmpty {
                        WearStrip(days: days)
                        HStack(spacing: 10) {
                            Label("data captured", systemImage: "chart.bar.fill")
                            HStack(spacing: 3) {
                                Circle().fill(Color.red).frame(width: 5, height: 5)
                                Text("calibration")
                            }
                            Text("% error that day")
                        }
                        .labelStyle(CompactLabelStyle())
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("Wear")
            }
            .task(id: refreshKey(context)) {
                days = await model.wearDays()
            }
        }
    }

    /// Recomputed every 15 minutes as readings arrive, and when fingersticks change.
    private func refreshKey(_ context: AppModel.WearContext) -> String {
        let bucket = Int((model.latest?.timestamp.timeIntervalSince1970 ?? 0) / 900)
        return "\(context.serial)-\(bucket)-\(model.fingersticks.count)"
    }

    private func remainingText(_ context: AppModel.WearContext, now: Date) -> String {
        let left = context.expiresAt.timeIntervalSince(now)
        if left <= 0 { return " · ended" }
        if left < 86_400 { return " · ends in \(Int((left / 3600).rounded(.up))) h" }
        let days = Int((left / 86_400).rounded(.down))
        return " · \(days) day\(days == 1 ? "" : "s") left"
    }
}

private struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon
            configuration.title
        }
    }
}

/// One column per day of wear.
struct WearStrip: View {
    let days: [SensorWearDay]

    var body: some View {
        HStack(alignment: .top, spacing: 3) {
            ForEach(days) { day in
                VStack(spacing: 3) {
                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.secondary.opacity(day.coverage == nil ? 0.06 : 0.14))
                        if let coverage = day.coverage {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(color(coverage))
                                .frame(height: max(2, 40 * coverage))
                        }
                    }
                    .frame(height: 40)
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(day.isToday ? Color.primary : .clear, lineWidth: 1.5))
                    Circle()
                        .fill(day.calibrations > 0 ? Color.red : .clear)
                        .frame(width: 5, height: 5)
                    Text("\(day.day)")
                        .font(.caption2.weight(day.isToday ? .bold : .regular))
                        .foregroundStyle(day.isToday ? .primary : .secondary)
                    Text(day.accuracy.map { String(format: "%.0f%%", $0.mard) } ?? " ")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    private func color(_ coverage: Double) -> Color {
        coverage >= 0.9 ? RangePalette.color(zone: 2) : coverage >= 0.7 ? RangePalette.color(zone: 3) : RangePalette.color(zone: 1)
    }

    private var accessibilitySummary: String {
        days.compactMap { day in
            guard let coverage = day.coverage else { return nil }
            var text = String(format: "Day %d: %.0f percent captured", day.day, coverage * 100)
            if day.calibrations > 0 { text += ", calibrated" }
            if let accuracy = day.accuracy { text += String(format: ", %.0f percent error", accuracy.mard) }
            return text
        }
        .joined(separator: ". ")
    }
}

/// Bluetooth link quality over the last 24 hours, and each gap with its reason.
struct SignalSections: View {
    @Environment(AppModel.self) private var model
    @Environment(SensorConnection.self) private var sensor

    private struct GapRow: Identifiable {
        let start: Date
        let end: Date?
        let reason: String
        let state: Status
        var id: Date { start }

        enum Status { case filled, missing, ongoing }
    }

    var body: some View {
        let now = Date()
        let window = DateInterval(start: now.addingTimeInterval(-86_400), end: now)
        let summary = sensor.signal.summary(in: window)
        let recent = model.readings(in: window)
        Section {
            if let rssi = summary.averageRSSI {
                MetricRow(label: "Bluetooth",
                          value: "\(Int(rssi.rounded())) dBm · \(SignalStats.SignalQuality(rssi: rssi).rawValue)",
                          warning: SignalStats.SignalQuality(rssi: rssi) == .weak)
            } else {
                MetricRow(label: "Bluetooth", value: "no measurement yet")
            }
            if let share = summary.packetShare {
                MetricRow(label: "Packets",
                          value: "\(Int((share * 100).rounded())) % · \(summary.packets.formatted()) of \(Int(summary.minutes.rounded()).formatted())",
                          warning: share < 0.9)
            }
            MetricRow(label: "Reconnects", value: "\(summary.reconnects)")
            MetricRow(label: "Checksum errors", value: "\(summary.corruptPackets)", warning: summary.corruptPackets > 10)
            MetricRow(label: "Unusable sensor values", value: "\(summary.unusableValues)", warning: summary.unusableValues > 30)
            if let noise = SignalStats.noise(in: recent) {
                MetricRow(label: "Noise",
                          value: "\(noise.level.rawValue.capitalized) (±\(model.unit.format(mgdL: noise.mgdL, includeSymbol: true)))",
                          warning: noise.level == .high)
            }
        } header: {
            Text("Signal, last 24 h")
        } footer: {
            Text("Signal strength depends on where the phone is: a pocket on the other side of the body, or sleeping on the sensor arm, weakens it. Packets counts one a minute since the app started counting.")
        }

        Section {
            let rows = gapRows(window: window, recent: recent, now: now)
            if rows.isEmpty {
                Text("No gaps in the last 24 hours.").foregroundStyle(.secondary)
            }
            ForEach(rows) { row in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(span(row))
                        Text(row.reason).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    chip(row.state)
                }
                .accessibilityElement(children: .combine)
            }
        } header: {
            Text("Gaps, last 24 h")
        }
    }

    private func gapRows(window: DateInterval, recent: [GlucoseReading], now: Date) -> [GapRow] {
        // Before a new sensor's first reading there's nothing to miss, nor more than 8 hours before
        // pairing (a sensor started with LibreLink): that's all a scan can bring back.
        let pairedAt = sensor.record.flatMap { record in
            sensor.history.entries.first { $0.id == record.uid.hexString }?.pairedAt
        }
        let start = max(window.start, (model.wearContext?.activatedAt ?? window.start).addingTimeInterval(3600),
                        (pairedAt ?? window.start).addingTimeInterval(-8 * 3600))
        // After the sensor's end there's nothing to miss either.
        let end = model.isDemo ? now : min(now, model.wearContext?.expiresAt ?? now)
        guard start < end else { return [] }
        let span = DateInterval(start: start, end: end)
        let outages = sensor.signal.outages(in: span, now: end)
        var rows = outages.map { outage -> GapRow in
            let interval = outage.interval(now: end)
            let inside = recent.filter { interval.contains($0.timestamp) }
            // Only the part inside the window can be judged: older readings aren't loaded here.
            let judged = interval.intersection(with: span) ?? interval
            let filled = outage.end != nil && SignalStats.isCovered(judged, by: recent)
            var reason: String
            switch outage.reason {
            case .bluetoothOff: reason = "Bluetooth was off on the phone"
            case .linkLost: reason = "Phone out of range, or the signal was blocked"
            case .appPaused: reason = "Paused while the app was closed (Run in background is off)"
            }
            if filled {
                if inside.contains(where: { $0.source == .nfc }) {
                    reason += " · filled by an NFC scan"
                } else if inside.contains(where: { $0.source == .backfill }) {
                    reason += " · filled from the sensor's memory (a scan or the reconnect)"
                }
            }
            return GapRow(start: interval.start, end: outage.end, reason: reason,
                          state: outage.end == nil ? .ongoing : filled ? .filled : .missing)
        }
        // Stretches without data that no outage explains: the app wasn't running.
        // Time spent in the demo or between sensors isn't a gap either.
        for gap in SignalStats.dataGaps(in: recent, interval: span)
        where !outages.contains(where: { $0.interval(now: end).intersects(gap) })
            && !sensor.signal.isNotReading(during: gap, now: end) {
            let ongoing = end == now && now.timeIntervalSince(gap.end) < 60
            rows.append(GapRow(start: gap.start, end: ongoing ? nil : gap.end,
                               reason: "No data received: the app may not have been running, or the phone was off",
                               state: ongoing ? .ongoing : .missing))
        }
        return rows.sorted { $0.start > $1.start }
    }

    private func span(_ row: GapRow) -> String {
        let start = row.start.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        guard let end = row.end else { return "\(start) – now" }
        return "\(start)–\(end.formatted(date: .omitted, time: .shortened))"
    }

    @ViewBuilder
    private func chip(_ state: GapRow.Status) -> some View {
        let text = state == .filled ? "filled" : state == .missing ? "missing" : "now"
        let color = state == .filled ? RangePalette.color(zone: 2) : state == .missing ? Color.orange : Color.red
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}
