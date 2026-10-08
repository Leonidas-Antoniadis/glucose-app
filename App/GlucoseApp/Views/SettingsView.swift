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

                Section {
                    Toggle("Bedtime check", isOn: $model.settings.bedtimeCheck)
                    if model.settings.bedtimeCheck {
                        DatePicker("Bedtime", selection: bedtimeBinding, displayedComponents: .hourAndMinute)
                    }
                    NavigationLink("Check now") { BedtimeCheckView() }
                } header: {
                    Text("Night")
                } footer: {
                    Text("From an hour before bedtime, Home checks what could keep an alarm from sounding overnight: volume, battery, Bluetooth, the no-data alert, Silent mode, the sensor's end and the app build. With the app closed, a notification at bedtime lists anything that needs fixing.")
                }

                BatteryAndLockScreenSections()

                Section {
                    Toggle("Lock with Face ID", isOn: $model.settings.biometricLock)
                    Toggle("Hide values on Lock Screen", isOn: $model.settings.hideValuesOnLockScreen)
                    NavigationLink("Backup and restore") { BackupView() }
                    Button("Delete all data", role: .destructive) { confirmDelete = true }
                } header: {
                    Text("Privacy")
                } footer: {
                    Text("Hide values on Lock Screen: alert notifications, the Live Activity and Lock Screen widgets say there's an alert without showing glucose. Alerts still sound.")
                }

                Section {
                    NavigationLink {
                        CalibrationGuideView()
                    } label: {
                        Label("Calibration and accuracy guide", systemImage: "book")
                    }
                    Link(destination: URL(string: "https://xdrip.readthedocs.io/en/latest/")!) {
                        Label("xDrip+ documentation", systemImage: "books.vertical")
                    }
                    Link(destination: URL(string: "https://xdrip4ios.readthedocs.io/en/latest/")!) {
                        Label("xDrip4iOS documentation", systemImage: "iphone")
                    }
                } header: {
                    Text("Help")
                } footer: {
                    Text("This app follows community practice from xDrip+ (Android) and xDrip4iOS, which read Libre 2 sensors the same way. Their documentation opens in Safari.")
                }

                Section("Diagnostics") {
                    NavigationLink("Raw sensor data") { RawDataView() }
                    NavigationLink("Sensor history") { SensorHistoryView() }
                    NavigationLink("Alert decision log") { DecisionLogView() }
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
                Text("Readings, notes, fingersticks and the sensor pairing are erased from this phone. Settings, the sensor history and imported tunes are kept.")
            }
        }
    }

    /// Bedtime is stored as minutes after midnight; the picker wants a date.
    private var bedtimeBinding: Binding<Date> {
        Binding {
            Calendar.current.date(bySettingHour: model.settings.bedtimeMinutes / 60, minute: model.settings.bedtimeMinutes % 60,
                                  second: 0, of: Date()) ?? Date()
        } set: { date in
            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
            model.settings.bedtimeMinutes = (parts.hour ?? 22) * 60 + (parts.minute ?? 0)
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
    /// A backup or restore is running (it takes a few seconds with months of readings).
    @State private var working = false

    var body: some View {
        Form {
            Section {
                SecureField("Password (at least 8 characters)", text: $password)
                Button {
                    working = true
                    Task {
                        do {
                            backupURL = try await model.makeBackup(password: password)
                        } catch {
                            message = error.localizedDescription
                        }
                        working = false
                    }
                } label: {
                    HStack {
                        Label("Create encrypted backup", systemImage: "lock.doc")
                        if working {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(password.count < 8 || working)
                if let backupURL, !working {
                    ShareLink(item: backupURL) { Label("Save or share backup", systemImage: "square.and.arrow.up") }
                }
            } header: {
                Text("Back up")
            } footer: {
                Text("Includes settings, alerts, readings, notes, fingersticks and the sensor pairing. Without the password the file can't be opened, and the password can't be recovered.")
            }

            Section("Restore") {
                Button("Choose backup file…", systemImage: "arrow.down.doc") { importing = true }
                    .disabled(working)
                if pendingRestore != nil {
                    SecureField("Backup password", text: $restorePassword)
                    Button {
                        guard let url = pendingRestore else { return }
                        working = true
                        Task {
                            do {
                                message = try await model.restoreBackup(from: url, password: restorePassword)
                                pendingRestore = nil
                                restorePassword = ""
                            } catch {
                                message = error.localizedDescription
                            }
                            working = false
                        }
                    } label: {
                        HStack {
                            Text("Restore")
                            if working {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(restorePassword.isEmpty || working)
                }
            }
        }
        .navigationTitle("Backup")
        // Leaving mid-way would let a second backup or restore start.
        .navigationBarBackButtonHidden(working)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data]) { result in
            if case .success(let url) = result { pendingRestore = url }
        }
        .alert(message ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") { message = nil }
        }
    }
}

/// Background running, Lock Screen Live Activity and how long data is kept.
struct BatteryAndLockScreenSections: View {
    @Environment(AppModel.self) private var model
    @State private var message: String?

    var body: some View {
        @Bindable var model = model
        Section {
            Toggle("Live Activity", isOn: $model.settings.liveActivity)
            Button("Show Live Activity again", systemImage: "rectangle.badge.plus") {
                message = model.restartLiveActivity() ?? "The Live Activity is back on the Lock Screen."
            }
        } header: {
            Text("Lock screen")
        } footer: {
            Text("If you swiped the glucose value off the Lock Screen, tap Show Live Activity again.")
        }
        .alert(message ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") { message = nil }
        }

        Section {
            Toggle("Run in background", isOn: $model.settings.runInBackground)
        } header: {
            Text("Battery")
        } footer: {
            Text(model.settings.runInBackground
                 ? "The app stays connected to the sensor while closed, so alerts work at any time."
                 : "Saves battery: the sensor connection stops when you leave the app and resumes when you open it. No glucose alerts and no Live Activity while the app is closed.")
                .foregroundStyle(model.settings.runInBackground ? Color.secondary : Color.orange)
        }

        Section {
            MetricRow(label: "Data kept on this phone", value: "\(Int(AppModel.archiveDays)) days")
        } footer: {
            Text("Readings, notes, fingersticks and raw captures older than \(Int(AppModel.archiveDays)) days are deleted automatically.")
        }
    }
}

/// The alert engine's decisions, newest first. Reads the model's observed log, so new decisions
/// appear while the screen is open.
struct DecisionLogView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            if model.decisionLog.isEmpty {
                Text("No alert decisions yet.").foregroundStyle(.secondary)
            }
            ForEach(Array(model.decisionLog.enumerated()), id: \.offset) { _, line in
                Text(line).font(.caption.monospaced())
            }
        }
        .navigationTitle("Decision log")
    }
}
