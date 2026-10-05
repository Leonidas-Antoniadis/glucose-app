import SwiftUI
import GlucoseCore

struct AlertsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            List {
                if !model.ruleSet.validate().isEmpty || model.lastError != nil {
                    Section {
                        ForEach(model.ruleSet.validate(), id: \.self) { issue in
                            Label(describe(issue), systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                        }
                        if let error = model.lastError {
                            Label(error, systemImage: "xmark.octagon").foregroundStyle(.red)
                        }
                    }
                }

                ForEach(AlertDirection.allCases, id: \.self) { direction in
                    Section {
                        ForEach(model.ruleSet.rules(for: direction).sorted { $0.isMoreSevere(than: $1) }) { rule in
                            NavigationLink {
                                RuleEditorView(rule: rule)
                            } label: {
                                RuleRow(rule: rule, unit: model.unit)
                            }
                            .swipeActions {
                                Button("Delete", role: .destructive) { model.removeRule(id: rule.id) }
                                Button("Duplicate") { model.duplicateRule(id: rule.id) }
                            }
                        }
                        if model.ruleSet.rules(for: direction).count < AlertRuleSet.maxRulesPerDirection {
                            Button {
                                model.addRule(direction)
                            } label: {
                                Label("Add \(direction.rawValue) rule", systemImage: "plus")
                            }
                        }
                    } header: {
                        Text(direction == .low ? "Low rules" : "High rules")
                    } footer: {
                        Text("Up to \(AlertRuleSet.maxRulesPerDirection). Only the most severe crossed rule sounds.")
                    }
                }

                Section("Missing data") {
                    Toggle("Alert when no data", isOn: $model.missingData.isEnabled)
                    Stepper(value: $model.missingData.minutes, in: MissingDataAlert.allowedMinutes, step: 5) {
                        Text("After \(model.missingData.minutes) min")
                    }
                    Toggle("Quiet during sensor warm-up", isOn: $model.missingData.suppressDuringWarmUp)
                }

                Section("Presets") {
                    Button("Basic (80 / 70 / 60, 180 / 220 / 250)") { model.applyPreset(.basic()) }
                    Button("Night") { model.applyPreset(.night()) }
                    Button("Sensitive") { model.applyPreset(.sensitive()) }
                }
            }
            .navigationTitle("Alerts")
        }
    }

    private func describe(_ issue: AlertRuleSet.Issue) -> String {
        let unit = model.unit
        switch issue {
        case .duplicateThreshold(let direction, let value):
            return "Two \(direction.rawValue) rules use \(unit.format(mgdL: value, includeSymbol: true))."
        case .lowAboveHigh(let low, let high):
            return "A low rule (\(unit.format(mgdL: low))) is at or above a high rule (\(unit.format(mgdL: high)))."
        case .noUrgentLow:
            return "No low rule at or below \(unit.format(mgdL: AlertRuleSet.urgentLowMgdL, includeSymbol: true))."
        case .noEnabledRules(let direction):
            return "No \(direction.rawValue) rules are enabled."
        }
    }
}

struct RuleRow: View {
    let rule: AlertRule
    let unit: GlucoseUnit

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(rule.name).font(.body.weight(.medium))
                Text(soundDescription).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(rule.direction == .low ? "<" : ">") \(unit.format(mgdL: rule.thresholdMgdL))")
                .monospacedDigit()
                .foregroundStyle(rule.isEnabled ? .primary : .secondary)
            if !rule.isEnabled {
                Image(systemName: "bell.slash").foregroundStyle(.secondary)
            }
        }
    }

    private var soundDescription: String {
        var parts: [String] = []
        switch rule.sound {
        case .silent: parts.append("Silent")
        case .tune(let name): parts.append("Tune: \(name)")
        case .voice(let clip): parts.append("Voice: \(clip)")
        }
        if rule.isCritical { parts.append("Critical") }
        if let repeatMinutes = rule.repeatIntervalMinutes { parts.append("repeat \(repeatMinutes) min") }
        if rule.schedule != .always { parts.append("scheduled") }
        return parts.joined(separator: " · ")
    }
}

struct RuleEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var rule: AlertRule

    init(rule: AlertRule) {
        _rule = State(initialValue: rule)
    }

    private enum SoundKind: String, CaseIterable, Identifiable {
        case silent = "Silent", tune = "Tune", voice = "Voice"
        var id: String { rawValue }
    }

    private enum ScheduleKind: String, CaseIterable, Identifiable {
        case always = "Always", night = "Night (22-07)", day = "Day (07-22)"
        var id: String { rawValue }

        var schedule: AlertSchedule {
            switch self {
            case .always: return .always
            case .night: return .nightOnly
            case .day: return AlertSchedule(startMinute: 7 * 60, endMinute: 22 * 60)
            }
        }
    }

    var body: some View {
        let unit = model.unit
        Form {
            Section {
                TextField("Name", text: $rule.name)
                Toggle("Enabled", isOn: $rule.isEnabled)
                Stepper(value: $rule.thresholdMgdL, in: AlertRuleSet.thresholdRangeMgdL, step: unit.editorStepMgdL) {
                    Text("\(rule.direction == .low ? "Below" : "Above") \(unit.format(mgdL: rule.thresholdMgdL, includeSymbol: true))")
                }
            }

            Section("Sound") {
                Picker("Style", selection: soundKind) {
                    ForEach(SoundKind.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("Critical Alert (bypass Silent / Focus)", isOn: $rule.isCritical)
                if rule.isCritical {
                    Slider(value: $rule.criticalVolume, in: 0...1) { Text("Volume") }
                    Text("Needs Apple's Critical Alerts entitlement; until then it's sent as Time Sensitive.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Timing") {
                Stepper(value: minutesBinding(\.repeatIntervalMinutes), in: 0...120, step: 1) {
                    Text(rule.repeatIntervalMinutes.map { "Repeat every \($0) min" } ?? "No repeat")
                }
                Stepper(value: $rule.snoozeMinutes, in: 5...240, step: 5) {
                    Text("Snooze \(rule.snoozeMinutes) min")
                }
                Stepper(value: $rule.confirmationMinutes, in: 0...60) {
                    Text(rule.confirmationMinutes == 0 ? "Alert immediately" : "Only if past for \(rule.confirmationMinutes) min")
                }
                Stepper(value: $rule.rearmMarginMgdL, in: 0...50, step: unit.editorStepMgdL) {
                    Text("Re-arm after recovering \(unit.format(mgdL: rule.rearmMarginMgdL, includeSymbol: true))")
                }
                Picker("Active", selection: scheduleKind) {
                    ForEach(ScheduleKind.allCases) { Text($0.rawValue).tag($0) }
                }
            }
        }
        .navigationTitle(rule.name)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    model.update(rule)
                    dismiss()
                }
            }
        }
    }

    private var soundKind: Binding<SoundKind> {
        Binding {
            switch rule.sound {
            case .silent: return .silent
            case .tune: return .tune
            case .voice: return .voice
            }
        } set: { kind in
            switch kind {
            case .silent: rule.sound = .silent
            case .tune: rule.sound = .tune(name: "chime")
            case .voice: rule.sound = .voice(clip: rule.direction == .low ? "glucose_low" : "glucose_high")
            }
        }
    }

    private var scheduleKind: Binding<ScheduleKind> {
        Binding {
            ScheduleKind.allCases.first { $0.schedule == rule.schedule } ?? .always
        } set: { kind in
            rule.schedule = kind.schedule
        }
    }

    /// Maps an optional minutes value to a stepper where 0 means "off".
    private func minutesBinding(_ keyPath: WritableKeyPath<AlertRule, Int?>) -> Binding<Int> {
        Binding {
            rule[keyPath: keyPath] ?? 0
        } set: { value in
            rule[keyPath: keyPath] = value == 0 ? nil : value
        }
    }
}
