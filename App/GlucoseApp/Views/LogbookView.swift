import SwiftUI
import GlucoseCore

/// What can be logged. Blood glucose is stored as a fingerstick; the rest as logbook notes.
enum QuickLogKind: String, CaseIterable, Identifiable {
    case fastInsulin, slowInsulin, food, exercise, bloodGlucose, note

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fastInsulin: return "Fast insulin"
        case .slowInsulin: return "Slow insulin"
        case .food: return "Food"
        case .exercise: return "Exercise"
        case .bloodGlucose: return "Blood glucose"
        case .note: return "Note"
        }
    }

    var symbolName: String {
        switch self {
        case .fastInsulin: return "syringe"
        case .slowInsulin: return "syringe.fill"
        case .food: return "fork.knife"
        case .exercise: return "figure.run"
        case .bloodGlucose: return "drop.fill"
        case .note: return "note.text"
        }
    }

    var tint: Color {
        switch self {
        case .fastInsulin: return .orange
        case .slowInsulin: return .purple
        case .food: return .green
        case .exercise: return .teal
        case .bloodGlucose: return .red
        case .note: return .gray
        }
    }
}

/// Logbook buttons that open the full form. The home screen uses `HomeQuickLog`.
struct QuickAddBar: View {
    let onSelect: (QuickLogKind) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(QuickLogKind.allCases) { kind in
                    Button {
                        onSelect(kind)
                    } label: {
                        QuickLogChip(kind: kind)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

struct LogbookView: View {
    @Environment(AppModel.self) private var model
    @State private var adding: QuickLogKind?
    /// A calibration fingerstick waiting for confirmation before it's deleted.
    @State private var pendingCalibrationDelete: FingerstickEntry?

    /// Notes and fingersticks in one timeline, newest first.
    private enum Row: Identifiable {
        case entry(LogEntry)
        case stick(FingerstickEntry)

        var id: UUID {
            switch self {
            case .entry(let entry): return entry.id
            case .stick(let stick): return stick.id
            }
        }

        var date: Date {
            switch self {
            case .entry(let entry): return entry.date
            case .stick(let stick): return stick.date
            }
        }
    }

    var body: some View {
        let rows = (model.logbook.map(Row.entry) + model.fingersticks.map(Row.stick)).sorted { $0.date > $1.date }
        let days = Dictionary(grouping: rows) { Calendar.current.startOfDay(for: $0.date) }

        NavigationStack {
            List {
                Section {
                    QuickAddBar { adding = $0 }
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                }
                if rows.isEmpty {
                    ContentUnavailableView("Nothing logged yet", systemImage: "book",
                                           description: Text("Log insulin, food, exercise and blood glucose. Entries appear as markers on the chart."))
                }
                ForEach(days.keys.sorted(by: >), id: \.self) { day in
                    Section(day.formatted(date: .complete, time: .omitted)) {
                        ForEach(days[day] ?? []) { row in
                            rowView(row)
                                .swipeActions {
                                    Button("Delete", role: .destructive) { delete(row) }
                                }
                        }
                    }
                }
            }
            .navigationTitle("Logbook")
            .sheet(item: $adding) { kind in AddLogEntryView(kind: kind) }
            .confirmationDialog("Delete this calibration?", isPresented: Binding(
                get: { pendingCalibrationDelete != nil }, set: { if !$0 { pendingCalibrationDelete = nil } }
            ), titleVisibility: .visible) {
                Button("Delete and undo calibration", role: .destructive) {
                    if let stick = pendingCalibrationDelete { model.deleteFingersticks([stick.id]) }
                    pendingCalibrationDelete = nil
                }
            } message: {
                Text("This fingerstick was used to calibrate the sensor. Deleting it removes it from the calibration, so glucose values will change.")
            }
        }
    }

    @ViewBuilder
    private func rowView(_ row: Row) -> some View {
        switch row {
        case .entry(let entry):
            HStack(alignment: .top) {
                Image(systemName: entry.symbolName).foregroundStyle(.blue).frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title)
                    if !entry.text.isEmpty {
                        Text(entry.text).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text(entry.date.formatted(date: .omitted, time: .shortened)).font(.caption).foregroundStyle(.secondary)
            }
        case .stick(let stick):
            HStack {
                Image(systemName: "drop.fill").foregroundStyle(.red).frame(width: 24)
                Text("Blood glucose · \(model.unit.format(mgdL: stick.mgdL, includeSymbol: true))")
                if stick.usedForCalibration {
                    Text("calibration").font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.blue.opacity(0.15), in: Capsule())
                }
                Spacer()
                Text(stick.date.formatted(date: .omitted, time: .shortened)).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func delete(_ row: Row) {
        switch row {
        case .entry(let entry): model.deleteLogEntries([entry.id])
        case .stick(let stick) where stick.usedForCalibration: pendingCalibrationDelete = stick
        case .stick(let stick): model.deleteFingersticks([stick.id])
        }
    }
}

struct AddLogEntryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var kind: QuickLogKind
    @State private var date = Date()
    @State private var amountText = ""
    @State private var minutes = 30
    @State private var text = ""
    @State private var calibrate = false
    @State private var result: String?

    init(kind: QuickLogKind = .food) {
        _kind = State(initialValue: kind)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Type", selection: $kind) {
                        ForEach(QuickLogKind.allCases) { Label($0.title, systemImage: $0.symbolName).tag($0) }
                    }
                    switch kind {
                    case .fastInsulin, .slowInsulin:
                        LabeledContent("Units") {
                            TextField("0", text: $amountText).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                        }
                    case .food:
                        LabeledContent("Carbs (g)") {
                            TextField("optional", text: $amountText).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                        }
                    case .exercise:
                        Stepper("\(minutes) min", value: $minutes, in: 5...300, step: 5)
                    case .bloodGlucose:
                        LabeledContent(model.unit.symbol) {
                            TextField("0", text: $amountText).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                        }
                        Toggle("Use to calibrate the sensor", isOn: $calibrate)
                    case .note:
                        EmptyView()
                    }
                    DatePicker("Time", selection: $date, in: ...Date().addingTimeInterval(3600))
                }
                if kind != .bloodGlucose {
                    Section {
                        TextField(kind == .food ? "What did you eat?" : "Note", text: $text, axis: .vertical)
                    }
                } else {
                    Section {
                        Text("Calibrate only when glucose is steady (flat arrow). Blood glucose values you don't use for calibration measure the sensor's accuracy instead.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let result {
                    Section { Text(result) }
                }
            }
            .navigationTitle("Add \(kind.title.lowercased())")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(result == nil ? "Cancel" : "Done") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(!isValid)
                }
            }
        }
    }

    private var amount: Double? {
        Double(amountText.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces))
    }

    private var isValid: Bool {
        switch kind {
        case .fastInsulin, .slowInsulin: return (amount ?? 0) > 0 && (amount ?? 0) <= 100
        case .bloodGlucose: return model.unit.parse(amountText).map { (20...600).contains($0) } ?? false
        case .food: return amountText.isEmpty || (amount ?? -1) >= 0
        case .exercise, .note: return true
        }
    }

    private func save() {
        switch kind {
        case .bloodGlucose:
            guard let mgdL = model.unit.parse(amountText) else { return }
            result = model.addFingerstick(mgdL: mgdL, date: date, calibrate: calibrate)
            amountText = ""
            return
        case .fastInsulin:
            model.addLogEntry(LogEntry(date: date, kind: .insulin(units: amount ?? 0, type: .rapid), text: text))
        case .slowInsulin:
            model.addLogEntry(LogEntry(date: date, kind: .insulin(units: amount ?? 0, type: .long), text: text))
        case .food:
            model.addLogEntry(LogEntry(date: date, kind: .meal(carbsGrams: amount), text: text))
        case .exercise:
            model.addLogEntry(LogEntry(date: date, kind: .exercise(minutes: minutes), text: text))
        case .note:
            model.addLogEntry(LogEntry(date: date, kind: .note, text: text))
        }
        dismiss()
    }
}

/// Kept for the sensor screen's "Add fingerstick" button.
struct AddFingerstickView: View {
    var body: some View {
        AddLogEntryView(kind: .bloodGlucose)
    }
}
