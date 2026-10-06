import SwiftUI
import UIKit
import GlucoseCore

/// The last 5 sensors with their IDs, for support calls.
struct SensorHistoryView: View {
    @Environment(SensorConnection.self) private var sensor
    @Environment(AppModel.self) private var model
    @State private var addingManual = false

    var body: some View {
        List {
            Section {
                Text("The last \(SensorHistory.limit) sensors, with the IDs support asks for. Add the serial printed on the box: the one computed from the sensor ID may not match it.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if sensor.history.entries.isEmpty {
                ContentUnavailableView("No sensors yet", systemImage: "sensor.tag.radiowaves.forward",
                                       description: Text("Sensors are added when you pair them. You can also add one you used with LibreLink."))
            }
            ForEach(sensor.history.entries) { entry in
                NavigationLink {
                    SensorHistoryDetailView(entry: entry)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(entry.printedSerial.isEmpty ? (entry.computedSerial.isEmpty ? entry.sensorType : entry.computedSerial) : entry.printedSerial)
                                .font(.body.monospaced())
                            Spacer()
                            Text(entry.isActive ? "In use" : (entry.endReason?.title ?? "Ended"))
                                .font(.caption)
                                .foregroundStyle(entry.isActive ? .green : (entry.endReason == .expired ? .secondary : Color.orange))
                        }
                        Text(dates(entry)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Sensor history")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Add", systemImage: "plus") { addingManual = true }
            }
        }
        .onChange(of: model.lockCount) { addingManual = false }
        .sheet(isPresented: $addingManual) {
            NavigationStack {
                SensorHistoryDetailView(entry: SensorHistoryEntry(sensorType: "Libre 2 Plus (EU)", startedAt: Date(), pairedAt: Date()),
                                        isNew: true)
            }
        }
    }

    private func dates(_ entry: SensorHistoryEntry) -> String {
        let start = entry.startedAt?.formatted(date: .abbreviated, time: .omitted) ?? "?"
        let end = entry.endedAt?.formatted(date: .abbreviated, time: .omitted) ?? (entry.isActive ? "now" : "?")
        return "\(entry.sensorType) · \(start) – \(end)"
    }
}

struct SensorHistoryDetailView: View {
    @Environment(SensorConnection.self) private var sensor
    @Environment(\.dismiss) private var dismiss
    @State private var entry: SensorHistoryEntry
    @State private var hasEnded: Bool
    @State private var copied = false
    @State private var confirmDelete = false
    let isNew: Bool

    init(entry: SensorHistoryEntry, isNew: Bool = false) {
        _entry = State(initialValue: entry)
        _hasEnded = State(initialValue: entry.endedAt != nil)
        self.isNew = isNew
    }

    var body: some View {
        Form {
            Section("Serial numbers") {
                TextField("Serial printed on the box", text: $entry.printedSerial)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .font(.body.monospaced())
                if !entry.computedSerial.isEmpty {
                    LabeledContent("From sensor ID") { Text(entry.computedSerial).font(.body.monospaced()).textSelection(.enabled) }
                }
                if !entry.uidHex.isEmpty {
                    LabeledContent("UID") { Text(entry.uidHex).font(.caption.monospaced()).textSelection(.enabled) }
                }
                if !entry.patchInfoHex.isEmpty {
                    LabeledContent("Patch info") { Text(entry.patchInfoHex).font(.caption.monospaced()).textSelection(.enabled) }
                }
            }

            Section("Wear") {
                TextField("Type", text: $entry.sensorType)
                DatePicker("Started", selection: Binding(get: { entry.startedAt ?? Date() }, set: { entry.startedAt = $0 }))
                if let expected = entry.expectedEnd {
                    LabeledContent("Planned end", value: expected.formatted(date: .abbreviated, time: .shortened))
                }
                Toggle("Ended", isOn: $hasEnded)
                if hasEnded {
                    DatePicker("Ended", selection: Binding(get: { entry.endedAt ?? Date() }, set: { entry.endedAt = $0 }))
                    Picker("Reason", selection: Binding(get: { entry.endReason ?? .expired }, set: { entry.endReason = $0 })) {
                        ForEach(SensorHistoryEntry.EndReason.allCases) { Text($0.title).tag($0) }
                    }
                }
            }

            Section("Note") {
                TextField("What happened? (e.g. fell off on day 9, error message)", text: $entry.note, axis: .vertical)
            }

            if !isNew {
                Section {
                    Button(copied ? "Copied" : "Copy details for support", systemImage: copied ? "checkmark" : "doc.on.doc") {
                        UIPasteboard.general.string = normalized.supportText { $0.formatted(date: .long, time: .shortened) }
                        copied = true
                    }
                    Button("Remove from history", role: .destructive) { confirmDelete = true }
                }
            }
        }
        .navigationTitle(isNew ? "Add sensor" : "Sensor")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isNew {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    if isNew {
                        sensor.addManualSensor(normalized)
                    } else {
                        sensor.updateHistory(normalized)
                    }
                    dismiss()
                }
            }
        }
        .confirmationDialog("Remove this sensor from the history?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                sensor.removeHistory(id: entry.id)
                dismiss()
            }
        }
    }

    /// Applies the "Ended" toggle to the entry.
    private var normalized: SensorHistoryEntry {
        var result = entry
        result.printedSerial = result.printedSerial.trimmingCharacters(in: .whitespaces).uppercased()
        if hasEnded {
            result.endedAt = result.endedAt ?? Date()
            result.endReason = result.endReason ?? .expired
        } else {
            result.endedAt = nil
            result.endReason = nil
        }
        return result
    }
}
