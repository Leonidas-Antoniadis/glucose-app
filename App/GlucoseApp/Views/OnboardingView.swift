import SwiftUI
import GlucoseCore

/// First launch: safety notice, units, alert preset and data source.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @State private var step = 0
    @State private var accepted = false
    @State private var preset = 0

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            VStack(spacing: 0) {
                TabView(selection: $step) {
                    page(icon: "drop.circle.fill", title: "Your glucose, on your phone only") {
                        Text("This app reads your FreeStyle Libre 2 or 2 Plus (EU) sensor directly over Bluetooth. Readings, alerts and reports stay on this iPhone. Nothing is sent to any cloud.")
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Not a medical device", systemImage: "exclamationmark.triangle.fill").font(.headline).foregroundStyle(.orange)
                            Text("It's a personal project without regulatory approval. Confirm with an approved meter before any insulin or treatment decision, and keep your reader or fingerstick meter as a backup.")
                        }
                        .padding()
                        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                        Toggle("I understand", isOn: $accepted)
                    }
                    .tag(0)

                    page(icon: "ruler", title: "Units") {
                        Picker("Unit", selection: $model.settings.unit) {
                            ForEach(GlucoseUnit.allCases, id: \.self) { Text($0.symbol).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        Text("You can switch any time. Alert thresholds convert automatically.")
                            .foregroundStyle(.secondary)
                    }
                    .tag(1)

                    page(icon: "bell.badge.fill", title: "Alerts") {
                        Picker("Preset", selection: $preset) {
                            Text("Basic").tag(0)
                            Text("Night").tag(1)
                            Text("Sensitive").tag(2)
                        }
                        .pickerStyle(.segmented)
                        Text(presetDescription).foregroundStyle(.secondary)
                        Text("Lows and highs use different alarm sounds. Everything can be changed later under Alerts.")
                            .foregroundStyle(.secondary)
                    }
                    .tag(2)

                    page(icon: "sensor.tag.radiowaves.forward.fill", title: "Data source") {
                        Picker("Source", selection: $model.settings.dataSource) {
                            ForEach(DataSource.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        Text(model.settings.dataSource == .demo
                             ? "Start with the demo sensor to try alerts and reports. Switch to your Libre sensor in Settings when you're ready."
                             : "After setup, open Sensor. Tap \"Pair sensor\" for a sensor started with LibreLink, or \"Start a new sensor\" to start one here.")
                            .foregroundStyle(.secondary)
                    }
                    .tag(3)
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
                .indexViewStyle(.page(backgroundDisplayMode: .always))

                Button {
                    if step < 3 {
                        withAnimation { step += 1 }
                    } else {
                        finish()
                    }
                } label: {
                    Text(step < 3 ? "Continue" : "Start")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!accepted)
                .padding()
            }
        }
    }

    private var presetDescription: String {
        switch preset {
        case 1: return "Night: louder, fewer alerts overnight, plus an always-on urgent low."
        case 2: return "Sensitive: earlier warnings with tighter thresholds."
        default: return "Basic: below 80 silent, below 70 alarm, below 60 voice; above 180 silent, above 220 alarm, above 250 voice."
        }
    }

    private func finish() {
        switch preset {
        case 1: model.settings.ruleSet = .night()
        case 2: model.settings.ruleSet = .sensitive()
        default: model.settings.ruleSet = .basic()
        }
        model.settings.onboardingDone = true
    }

    private func page<Content: View>(icon: String, title: String, @ViewBuilder content: () -> Content) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Image(systemName: icon)
                    .font(.system(size: 48))
                    .foregroundStyle(.tint)
                Text(title).font(.title.bold())
                content()
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
