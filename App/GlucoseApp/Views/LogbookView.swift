import SwiftUI
import GlucoseCore

struct LogbookView: View {
    @Environment(AppModel.self) private var model
    @State private var section = 0
    @State private var showingAddEntry = false
    @State private var showingAddFingerstick = false

    var body: some View {
        NavigationStack {
            List {
                Picker("Show", selection: $section) {
                    Text("Notes").tag(0)
                    Text("Fingersticks").tag(1)
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)

                if section == 0 {
                    if model.logbook.isEmpty {
                        ContentUnavailableView("No notes yet", systemImage: "note.text",
                                               description: Text("Log meals, insulin and exercise. They appear as markers on the chart."))
                    }
                    ForEach(model.logbook) { entry in
                        HStack(alignment: .top) {
                            Image(systemName: entry.symbolName).foregroundStyle(.blue).frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.title)
                                if !entry.text.isEmpty {
                                    Text(entry.text).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .onDelete { offsets in
                        model.deleteLogEntries(Set(offsets.map { model.logbook[$0].id }))
                    }
                } else {
                    if model.fingersticks.isEmpty {
                        ContentUnavailableView("No fingersticks yet", systemImage: "drop",
                                               description: Text("Fingersticks calibrate the sensor and measure its accuracy."))
                    }
                    ForEach(model.fingersticks) { stick in
                        HStack {
                            Text(model.unit.format(mgdL: stick.mgdL, includeSymbol: true)).monospacedDigit()
                            if stick.usedForCalibration {
                                Text("calibration").font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(.blue.opacity(0.15), in: Capsule())
                            }
                            Spacer()
                            Text(stick.date.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .onDelete { offsets in
                        model.deleteFingersticks(Set(offsets.map { model.fingersticks[$0].id }))
                    }
                }
            }
            .navigationTitle("Logbook")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Add note", systemImage: "note.text.badge.plus") { showingAddEntry = true }
                        Button("Add fingerstick", systemImage: "drop") { showingAddFingerstick = true }
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingAddEntry) { AddLogEntryView() }
            .sheet(isPresented: $showingAddFingerstick) { AddFingerstickView() }
        }
    }
}

struct AddLogEntryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private enum Kind: String, CaseIterable, Identifiable {
        case meal = "Meal", insulin = "Insulin", exercise = "Exercise", note = "Note"
        var id: String { rawValue }
    }

    @State private var kind: Kind = .meal
    @State private var date = Date()
    @State private var carbs: Double?
    @State private var units: Double?
    @State private var insulinType: LogEntry.InsulinType = .rapid
    @State private var minutes: Int = 30
    @State private var text = ""

    var body: some View {
        NavigationStack {
            Form {
                Picker("Type", selection: $kind) {
                    ForEach(Kind.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                switch kind {
                case .meal:
                    TextField("Carbs (g), optional", value: $carbs, format: .number)
                        .keyboardType(.decimalPad)
                case .insulin:
                    TextField("Units", value: $units, format: .number)
                        .keyboardType(.decimalPad)
                    Picker("Insulin", selection: $insulinType) {
                        ForEach(LogEntry.InsulinType.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                    }
                case .exercise:
                    Stepper("\(minutes) min", value: $minutes, in: 5...300, step: 5)
                case .note:
                    EmptyView()
                }
                DatePicker("Time", selection: $date)
                TextField("Note", text: $text, axis: .vertical)
            }
            .navigationTitle("Add note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        model.addLogEntry(LogEntry(date: date, kind: entryKind, text: text))
                        dismiss()
                    }
                    .disabled(kind == .insulin && (units ?? 0) <= 0)
                }
            }
        }
    }

    private var entryKind: LogEntry.Kind {
        switch kind {
        case .meal: return .meal(carbsGrams: carbs)
        case .insulin: return .insulin(units: units ?? 0, type: insulinType)
        case .exercise: return .exercise(minutes: minutes)
        case .note: return .note
        }
    }
}

struct AddFingerstickView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var valueText = ""
    @State private var date = Date()
    @State private var calibrate = true
    @State private var result: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Value in \(model.unit.symbol)", text: $valueText)
                        .keyboardType(.decimalPad)
                    DatePicker("Time", selection: $date, in: ...Date())
                    Toggle("Use to calibrate the sensor", isOn: $calibrate)
                } footer: {
                    Text("Calibrate when glucose is steady (flat arrow), with clean, dry hands. Fingersticks you don't use for calibration measure the sensor's accuracy instead.")
                }
                if let result {
                    Section { Text(result) }
                }
            }
            .navigationTitle("Fingerstick")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(result == nil ? "Cancel" : "Done") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let mgdL = model.unit.parse(valueText) else { return }
                        result = model.addFingerstick(mgdL: mgdL, date: date, calibrate: calibrate)
                        valueText = ""
                    }
                    .disabled(model.unit.parse(valueText).map { !(20...600).contains($0) } ?? true)
                }
            }
        }
    }
}
