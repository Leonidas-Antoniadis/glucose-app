import SwiftUI
import MediaPlayer
import GlucoseCore

/// The Home card shown in the evening: what needs fixing before sleep, what's fine, and tonight
/// so far.
struct BedtimeCard: View {
    @Environment(AppModel.self) private var model
    @State private var dismissed = false

    var body: some View {
        if !dismissed {
            // Re-read every few seconds: raising the volume or plugging in shows up right away.
            TimelineView(.periodic(from: .now, by: 5)) { context in
                content(now: context.date)
            }
        }
    }

    private func content(now: Date) -> some View {
        let items = model.bedtimeItems(now: now)
        let toFix = items.filter { $0.status != .ok }
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Ready for tonight?", systemImage: "moon.stars.fill")
                    .font(.headline)
                Spacer()
                Text(toFix.isEmpty ? "All set" : "Fix \(toFix.count)")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background((toFix.isEmpty ? RangePalette.color(zone: 2) : Color.orange).opacity(0.18), in: Capsule())
                    .foregroundStyle(toFix.isEmpty ? RangePalette.color(zone: 2) : Color.orange)
            }
            BedtimeChecklist(items: items, compact: true)
            let tonight = model.tonightSummary(now: now)
            if !tonight.isEmpty {
                Text("Tonight: " + tonight.joined(separator: " · "))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            HStack {
                NavigationLink {
                    BedtimeCheckView()
                } label: {
                    Text("Details")
                }
                Spacer()
                Button("Done") {
                    model.dismissBedtimeCard(at: now)
                    withAnimation { dismissed = true }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

/// The checks: problems and warnings with a way to fix them, then the passed ones.
struct BedtimeChecklist: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    let items: [BedtimeItem]
    /// On Home the passed checks fold into one line.
    var compact = false

    var body: some View {
        let passed = items.filter { $0.status == .ok }
        VStack(alignment: .leading, spacing: 10) {
            ForEach(items.filter { $0.status != .ok }) { item in
                row(item)
            }
            if compact {
                if !passed.isEmpty {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(passed.count) check\(passed.count == 1 ? "" : "s") passed")
                            Text(passed.map(\.title).joined(separator: " · "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(RangePalette.color(zone: 2))
                    }
                    .font(.subheadline)
                }
            } else {
                ForEach(passed) { item in
                    row(item)
                }
            }
        }
    }

    private func row(_ item: BedtimeItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).font(.subheadline.weight(item.status == .ok ? .regular : .semibold))
                    if !item.detail.isEmpty {
                        Text(item.detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
            } icon: {
                Image(systemName: icon(item.status)).foregroundStyle(color(item.status))
            }
            fix(item)
                .padding(.leading, 30)
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func fix(_ item: BedtimeItem) -> some View {
        switch item.fix {
        case .raiseVolume:
            SystemVolumeSlider().frame(height: 34)
        case .runInBackground:
            Button("Turn on Run in background") { model.settings.runInBackground = true }
                .buttonStyle(.bordered).controlSize(.small)
        case .missingDataAlert:
            Button("Turn on the no-data alert") { model.settings.missingData.isEnabled = true }
                .buttonStyle(.bordered).controlSize(.small)
        case .urgentLowThroughSilent:
            Button("Let urgent low sound through Silent") {
                let ids = Set(model.settings.ruleSet.urgentLowRules.map(\.id))
                model.updateRules { set in
                    for rule in set.rules where ids.contains(rule.id) {
                        var changed = rule
                        changed.isCritical = true
                        try set.update(changed)
                    }
                }
            }
            .buttonStyle(.bordered).controlSize(.small)
        case .notificationSettings:
            Button("Open Settings") { openNotificationSettings(openURL) }
                .buttonStyle(.bordered).controlSize(.small)
        case .openSensor:
            NavigationLink("Open Sensor") { SensorView() }
                .buttonStyle(.bordered).controlSize(.small)
        case .charge, .bluetooth, .newBuild, .none:
            EmptyView()
        }
    }

    private func icon(_ status: BedtimeItem.Status) -> String {
        switch status {
        case .problem: return "exclamationmark.triangle.fill"
        case .warning: return "exclamationmark.circle.fill"
        case .ok: return "checkmark.circle.fill"
        }
    }

    private func color(_ status: BedtimeItem.Status) -> Color {
        switch status {
        case .problem: return .red
        case .warning: return .orange
        case .ok: return RangePalette.color(zone: 2)
        }
    }
}

/// The whole check on its own screen, from Settings or the Home card.
struct BedtimeCheckView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { context in
            List {
                Section {
                    BedtimeChecklist(items: model.bedtimeItems(now: context.date))
                        .padding(.vertical, 4)
                } footer: {
                    Text("Alarms the app plays itself follow the media volume. The phone's ring switch and Focus don't silence alerts set to sound through Silent mode.")
                }
                let tonight = model.tonightSummary(now: context.date)
                if !tonight.isEmpty {
                    Section("Tonight") {
                        ForEach(tonight, id: \.self) { Text($0) }
                    }
                }
            }
        }
        .navigationTitle("Bedtime check")
    }
}

/// The system volume slider: the only way an app may change the volume.
struct SystemVolumeSlider: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: .zero)
        view.showsVolumeSlider = true
        return view
    }

    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}
