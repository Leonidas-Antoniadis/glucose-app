import SwiftUI
import GlucoseCore
import LibreProtocol

struct SensorView: View {
    @Environment(AppModel.self) private var model
    @Environment(SensorConnection.self) private var sensor
    @State private var confirmForget = false
    @State private var showingFingerstick = false

    var body: some View {
        @Bindable var model = model
        List {
            Section("Status") {
                MetricRow(label: "Connection", value: model.isDemo ? "Demo sensor (simulated)" : sensor.status.title)
                if let record = model.isDemo ? sensor.demoRecord : sensor.record {
                    MetricRow(label: "Type", value: record.type.displayName)
                    MetricRow(label: "Serial (computed)", value: record.serial)
                    MetricRow(label: "Started", value: record.activatedAt.formatted(date: .abbreviated, time: .shortened))
                    MetricRow(label: "Ends", value: record.expiresAt.formatted(date: .abbreviated, time: .shortened),
                              warning: record.expiresAt.timeIntervalSinceNow < 86_400)
                    if let last = sensor.lastPacketAt {
                        MetricRow(label: "Last Bluetooth packet", value: last.formatted(date: .omitted, time: .standard))
                    }
                }
            }

            Section {
                NavigationLink {
                    RawDataView()
                } label: {
                    Label("Raw sensor data", systemImage: "list.bullet.rectangle")
                }
                NavigationLink {
                    SensorHistoryView()
                } label: {
                    Label("Sensor history (last \(SensorHistory.limit))", systemImage: "clock.arrow.circlepath")
                }
            }

            Section {
                Button {
                    Task { await sensor.pair() }
                } label: {
                    Label(sensor.record == nil ? "Pair sensor (NFC)" : "Pair a new sensor (NFC)", systemImage: "wave.3.right")
                }
                .disabled(sensor.isBusy)
                if sensor.record != nil {
                    Button {
                        Task { await sensor.scanHistory() }
                    } label: {
                        Label("Scan to fill gaps (last 8 hours)", systemImage: "arrow.down.doc")
                    }
                    .disabled(sensor.isBusy)
                }
            } header: {
                Text("Pairing")
            } footer: {
                Text("Start a new sensor with LibreLink or the Abbott reader first and let it warm up. Then pair it here: this app takes over the Bluetooth connection, so LibreLink's alarms stop for this sensor. European Libre 2 and 2 Plus only.")
            }

            if let record = sensor.record {
                Section {
                    MetricRow(label: "Calibration",
                              value: record.calibration.isCalibrated ? "\(record.calibration.pointCount) fingerstick(s)" : "Not calibrated",
                              warning: record.calibration.needsCalibration(now: Date()))
                    if let last = record.calibration.lastCalibration {
                        MetricRow(label: "Last calibration", value: last.formatted(.relative(presentation: .named)))
                    }
                    Button("Add fingerstick", systemImage: "drop") { showingFingerstick = true }
                } header: {
                    Text("Calibration")
                } footer: {
                    Text("Abbott's conversion algorithm isn't public, so this app calibrates the sensor's raw signal against your fingersticks. Calibrate at least once a day.")
                }
            }

            Section("Accuracy") {
                let report = model.accuracy
                if let mard = report.mard, let within = report.within15_15 {
                    MetricRow(label: "MARD", value: String(format: "%.1f %%", mard), warning: mard > 15)
                    MetricRow(label: "Within 15 mg/dL or 15%", value: String(format: "%.0f %%", within * 100))
                    MetricRow(label: "Comparisons", value: "\(report.pairs.count)")
                } else {
                    Text("Add fingersticks without \"Use to calibrate\" to measure accuracy.")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Diagnostics") {
                NavigationLink("Connection log") {
                    List(sensor.debugLog, id: \.self) { line in
                        Text(line).font(.caption.monospaced())
                    }
                    .navigationTitle("Connection log")
                }
                if FileManager.default.fileExists(atPath: model.stores.capturesURL.path) {
                    ShareLink(item: model.stores.capturesURL) {
                        Label("Share raw sensor captures", systemImage: "square.and.arrow.up")
                    }
                }
                Toggle("Try unrecognized sensor types", isOn: $model.settings.allowUnverifiedSensorTypes)
            }

            if sensor.record != nil {
                Section {
                    Button("Forget this sensor", role: .destructive) { confirmForget = true }
                }
            }
        }
        .navigationTitle("Sensor")
        .sheet(isPresented: $showingFingerstick) { AddFingerstickView() }
        .confirmationDialog("Forget this sensor?", isPresented: $confirmForget, titleVisibility: .visible) {
            Button("Forget", role: .destructive) { sensor.forget() }
        } message: {
            Text("The app stops connecting to it. Readings already saved are kept.")
        }
    }
}
