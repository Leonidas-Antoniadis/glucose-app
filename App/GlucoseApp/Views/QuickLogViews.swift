import SwiftUI
import GlucoseCore

/// Something just logged from the home screen, shown with an Undo button.
struct LoggedToast: Identifiable, Equatable {
    let id = UUID()
    let message: String
    let entryIDs: Set<UUID>
}

/// The home screen's logging buttons. Insulin opens a small sheet, food logs in one tap,
/// and a long press repeats the last dose or opens the full form.
struct HomeQuickLog: View {
    @Environment(AppModel.self) private var model
    @Binding var logged: LoggedToast?
    @State private var doseSheet: LogEntry.InsulinType?
    @State private var fullForm: QuickLogKind?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(QuickLogKind.allCases) { kind in
                        Button { tap(kind) } label: { QuickLogChip(kind: kind) }
                            .buttonStyle(.plain)
                            .contentShape(.contextMenuPreview, Capsule())
                            .contextMenu { menu(for: kind) }
                    }
                }
            }
            LastLoggedTiles()
        }
        .sheet(item: $doseSheet) { type in
            QuickDoseSheet(type: type) { entries, message in log(entries, message) }
        }
        .sheet(item: $fullForm) { kind in AddLogEntryView(kind: kind) }
        .onChange(of: model.lockCount) {
            doseSheet = nil
            fullForm = nil
        }
    }

    private func tap(_ kind: QuickLogKind) {
        switch kind {
        case .fastInsulin: doseSheet = .rapid
        case .slowInsulin: doseSheet = .long
        case .food: log([LogEntry(date: Date(), kind: .meal(carbsGrams: nil))], "Food logged")
        default: fullForm = kind
        }
    }

    @ViewBuilder
    private func menu(for kind: QuickLogKind) -> some View {
        switch kind {
        case .fastInsulin, .slowInsulin:
            let type: LogEntry.InsulinType = kind == .fastInsulin ? .rapid : .long
            if let last = QuickLog.lastInsulin(type, in: model.logbook) {
                Button("Log \(LogEntry.format(last.units)) U again", systemImage: "arrow.counterclockwise") {
                    log([LogEntry(date: Date(), kind: .insulin(units: last.units, type: type))],
                        "\(kind.title) \(LogEntry.format(last.units)) U logged")
                }
            }
            Button("More options", systemImage: "slider.horizontal.3") { fullForm = kind }
        case .food:
            Button("Food with details", systemImage: "square.and.pencil") { fullForm = .food }
        default:
            EmptyView()
        }
    }

    private func log(_ entries: [LogEntry], _ message: String) {
        entries.forEach(model.addLogEntry)
        withAnimation { logged = LoggedToast(message: message, entryIDs: Set(entries.map(\.id))) }
    }
}

/// A colored capsule for one kind of log entry.
struct QuickLogChip: View {
    let kind: QuickLogKind

    var body: some View {
        Label(kind.title, systemImage: kind.symbolName)
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(kind.tint.opacity(0.15), in: Capsule())
            .foregroundStyle(kind.tint)
    }
}

/// When you last took fast insulin, ate and took slow insulin, with the clock time,
/// so a dose isn't taken twice by mistake.
struct LastLoggedTiles: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        TimelineView(.everyMinute) { context in
            let fast = QuickLog.lastInsulin(.rapid, in: model.logbook)
            let slow = QuickLog.lastInsulin(.long, in: model.logbook)
            // At accessibility text sizes three tiles side by side would cut off the times they
            // exist to show, so they stack.
            let layout = dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))
            layout {
                tile(.fastInsulin, amount: fast.map { "\(LogEntry.format($0.units)) U" }, date: fast?.date, now: context.date)
                tile(.food, amount: nil, date: QuickLog.lastMeal(in: model.logbook), now: context.date)
                tile(.slowInsulin, amount: slow.map { "\(LogEntry.format($0.units)) U" }, date: slow?.date, now: context.date)
            }
        }
    }

    private func tile(_ kind: QuickLogKind, amount: String?, date: Date?, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(kind.title, systemImage: kind.symbolName)
                .font(.caption.weight(.medium))
                .foregroundStyle(kind.tint)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            if let date, now.timeIntervalSince(date) < 24 * 3600 {
                // Side by side when it fits; a 12-hour time with a dose ("10:45 PM 12.5 U") doesn't
                // in a third of a phone's width, so the dose then goes on its own line.
                let time = Text(date.formatted(date: .omitted, time: .shortened)).font(.headline)
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        time
                        if let amount {
                            Text(amount).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        time.minimumScaleFactor(0.8)
                        if let amount {
                            Text(amount).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
                .monospacedDigit()
                .lineLimit(1)
                Text(Self.ago(date, now: now))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("–").font(.headline)
                Text("none in 24 h").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(kind.tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }

    private static let formatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    static func ago(_ date: Date, now: Date) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "just now" }
        return (formatter.string(from: seconds) ?? "") + " ago"
    }
}

/// A small sheet for logging insulin without the keyboard.
struct QuickDoseSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let type: LogEntry.InsulinType
    let onLog: ([LogEntry], String) -> Void

    @State private var units: Double?
    @State private var ate: Bool
    @State private var minutesAgo = 0
    @State private var note = ""

    private let step = 0.5

    init(type: LogEntry.InsulinType, onLog: @escaping ([LogEntry], String) -> Void) {
        self.type = type
        self.onLog = onLog
        _ate = State(initialValue: type == .rapid)
    }

    private var kind: QuickLogKind { type == .rapid ? .fastInsulin : .slowInsulin }

    /// Starts at the last dose of this type.
    private var amount: Double { units ?? QuickLog.lastInsulin(type, in: model.logbook)?.units ?? 0 }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    HStack(spacing: 24) {
                        stepButton("minus", by: -step)
                        VStack(spacing: 0) {
                            Text(LogEntry.format(amount))
                                .font(.system(size: 56, weight: .bold, design: .rounded))
                                .monospacedDigit()
                                .contentTransition(.numericText())
                            Text("units").font(.subheadline).foregroundStyle(.secondary)
                        }
                        .frame(minWidth: 120)
                        stepButton("plus", by: step)
                    }

                    let doses = QuickLog.usualDoses(type, in: model.logbook, now: Date())
                    if !doses.isEmpty {
                        HStack(spacing: 8) {
                            ForEach(doses, id: \.self) { dose in
                                Button {
                                    withAnimation { units = dose }
                                } label: {
                                    Text(LogEntry.format(dose))
                                        .font(.headline)
                                        .frame(minWidth: 44, minHeight: 36)
                                        .background(kind.tint.opacity(dose == amount ? 0.35 : 0.12), in: Capsule())
                                        .foregroundStyle(kind.tint)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    if type == .rapid {
                        Toggle(isOn: $ate) {
                            Label("Eating now too", systemImage: QuickLogKind.food.symbolName)
                        }
                        .tint(QuickLogKind.food.tint)
                    }

                    Picker("When", selection: $minutesAgo) {
                        Text("Now").tag(0)
                        Text("15 min ago").tag(15)
                        Text("30 min ago").tag(30)
                        Text("1 h ago").tag(60)
                    }
                    .pickerStyle(.segmented)

                    TextField("Note (optional)", text: $note)
                        .textFieldStyle(.roundedBorder)

                    Button(action: save) {
                        Text(saveTitle).font(.headline).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(kind.tint)
                    .disabled(amount <= 0)
                }
                .padding()
            }
            .navigationTitle(kind.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .presentationDetents([.fraction(0.65), .large])
    }

    private var saveTitle: String {
        "Log \(LogEntry.format(amount)) U" + (type == .rapid && ate ? " + food" : "")
    }

    private func stepButton(_ symbol: String, by delta: Double) -> some View {
        Button {
            withAnimation { units = min(100, max(0, amount + delta)) }
        } label: {
            Image(systemName: symbol)
                .font(.title2.weight(.semibold))
                .frame(width: 56, height: 56)
                .background(kind.tint.opacity(0.15), in: Circle())
                .foregroundStyle(kind.tint)
        }
        .buttonStyle(.plain)
        .buttonRepeatBehavior(.enabled)
        .accessibilityLabel(delta > 0 ? "More units" : "Fewer units")
    }

    private func save() {
        let date = Date().addingTimeInterval(-Double(minutesAgo) * 60)
        var entries = [LogEntry(date: date, kind: .insulin(units: amount, type: type), text: note)]
        let withFood = type == .rapid && ate
        if withFood {
            entries.append(LogEntry(date: date, kind: .meal(carbsGrams: nil)))
        }
        onLog(entries, "\(kind.title) \(LogEntry.format(amount)) U\(withFood ? " + food" : "") logged")
        dismiss()
    }
}

/// A short-lived message at the bottom of the home screen with an Undo button.
struct UndoToast: View {
    let toast: LoggedToast
    let onUndo: () -> Void

    var body: some View {
        HStack {
            Label {
                Text(toast.message)
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
            .font(.subheadline.weight(.medium))
            Spacer()
            Button("Undo", action: onUndo)
                .font(.subheadline.weight(.semibold))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
    }
}
