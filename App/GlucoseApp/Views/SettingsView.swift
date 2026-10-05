import SwiftUI
import GlucoseCore

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                Section("Units") {
                    Picker("Unit", selection: $model.unit) {
                        ForEach(GlucoseUnit.allCases, id: \.self) { Text($0.symbol).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }

                Section {
                    Picker("Demo speed", selection: $model.demoSpeed) {
                        ForEach(DemoSpeed.allCases) { Text($0.rawValue).tag($0) }
                    }
                } header: {
                    Text("Simulated sensor")
                } footer: {
                    Text("60x plays one simulated minute per second, so you can watch alerts fire. Missing-data alerts only run in real time.")
                }

                Section("Diagnostics") {
                    NavigationLink("Alert decision log") {
                        List(model.decisionLog, id: \.self) { line in
                            Text(line).font(.caption.monospaced())
                        }
                        .navigationTitle("Decision log")
                    }
                }

                Section("About") {
                    Text("Personal, local-only app. Not a medical device: confirm with an approved meter before any treatment decision. No data leaves this phone.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
        }
    }
}
