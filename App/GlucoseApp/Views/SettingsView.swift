import SwiftUI
import UniformTypeIdentifiers
import GlucoseCore

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var importingTune = false
    @State private var confirmDelete = false
    @State private var message: String?

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                Section("Units") {
                    Picker("Unit", selection: $model.settings.unit) {
                        ForEach(GlucoseUnit.allCases, id: \.self) { Text($0.symbol).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }

                Section {
                    Picker("Source", selection: $model.settings.dataSource) {
                        ForEach(DataSource.allCases) { Text($0.title).tag($0) }
                    }
                    if model.settings.dataSource == .demo {
                        Picker("Demo speed", selection: $model.settings.demoSpeed) {
                            ForEach(DemoSpeed.allCases) { Text($0.rawValue).tag($0) }
                        }
                    }
                    NavigationLink("Sensor") { SensorView() }
                } header: {
                    Text("Data source")
                } footer: {
                    Text(model.settings.dataSource == .demo
                         ? "The demo sensor follows a made-up curve that crosses low and high alerts. 60x plays one minute per second."
                         : "Readings come from your Libre sensor over Bluetooth.")
                }

                Section {
                    Toggle("Speak value with alerts (app open)", isOn: $model.settings.speakValues)
                    Toggle("Alert when Bluetooth is off", isOn: $model.settings.bluetoothAlert)
                    Toggle("Alert when phone battery is low", isOn: $model.settings.batteryAlert)
                    Button("Import a tune…", systemImage: "music.note") { importingTune = true }
                    ForEach(SoundCatalog.customTunes()) { tune in
                        Text(tune.title).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Alerts")
                } footer: {
                    Text("Imported tunes can be chosen in any alert. iOS plays up to 30 seconds.")
                }

                Section("Lock screen") {
                    Toggle("Live Activity", isOn: $model.settings.liveActivity)
                }

                Section("Privacy") {
                    Toggle("Lock with Face ID", isOn: $model.settings.biometricLock)
                    NavigationLink("Backup and restore") { BackupView() }
                    Button("Delete all data", role: .destructive) { confirmDelete = true }
                }

                Section("Diagnostics") {
                    NavigationLink("Raw sensor data") { RawDataView() }
                    NavigationLink("Sensor history") { SensorHistoryView() }
                    NavigationLink("Alert decision log") {
                        List(model.decisionLog, id: \.self) { line in
                            Text(line).font(.caption.monospaced())
                        }
                        .navigationTitle("Decision log")
                    }
                }

                Section("About") {
                    MetricRow(label: "Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-")
                    if let expiry = model.signatureExpiry {
                        MetricRow(label: "App build expires", value: expiry.formatted(date: .abbreviated, time: .shortened),
                                  warning: expiry.timeIntervalSinceNow < 2 * 86_400)
                    }
                    Text("Personal, local-only app. Not a medical device: confirm with an approved meter before any treatment decision. No data leaves this phone unless you export it.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .fileImporter(isPresented: $importingTune, allowedContentTypes: [.audio]) { result in
                switch result {
                case .success(let url):
                    do {
                        _ = try SoundCatalog.importTune(from: url)
                        message = "Tune imported."
                    } catch {
                        message = error.localizedDescription
                    }
                case .failure(let error):
                    message = error.localizedDescription
                }
            }
            .alert(message ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("OK") { message = nil }
            }
            .confirmationDialog("Delete all data?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete everything", role: .destructive) { model.deleteAllData() }
            } message: {
                Text("Readings, notes, fingersticks and the sensor pairing are erased from this phone. Settings are kept.")
            }
        }
    }
}

struct BackupView: View {
    @Environment(AppModel.self) private var model
    @State private var password = ""
    @State private var backupURL: URL?
    @State private var importing = false
    @State private var restorePassword = ""
    @State private var pendingRestore: URL?
    @State private var message: String?

    var body: some View {
        Form {
            Section {
                SecureField("Password (at least 8 characters)", text: $password)
                Button("Create encrypted backup", systemImage: "lock.doc") {
                    do {
                        backupURL = try model.makeBackup(password: password)
                    } catch {
                        message = error.localizedDescription
                    }
                }
                .disabled(password.count < 8)
                if let backupURL {
                    ShareLink(item: backupURL) { Label("Save or share backup", systemImage: "square.and.arrow.up") }
                }
            } header: {
                Text("Back up")
            } footer: {
                Text("Includes settings, alerts, readings, notes, fingersticks and the sensor pairing. Without the password the file can't be opened, and the password can't be recovered.")
            }

            Section("Restore") {
                Button("Choose backup file…", systemImage: "arrow.down.doc") { importing = true }
                if pendingRestore != nil {
                    SecureField("Backup password", text: $restorePassword)
                    Button("Restore") {
                        guard let url = pendingRestore else { return }
                        do {
                            message = try model.restoreBackup(from: url, password: restorePassword)
                            pendingRestore = nil
                            restorePassword = ""
                        } catch {
                            message = error.localizedDescription
                        }
                    }
                    .disabled(restorePassword.isEmpty)
                }
            }
        }
        .navigationTitle("Backup")
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data]) { result in
            if case .success(let url) = result { pendingRestore = url }
        }
        .alert(message ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") { message = nil }
        }
    }
}
