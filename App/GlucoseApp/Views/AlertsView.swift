import SwiftUI
import GlucoseCore

struct AlertsView: View {
    @Environment(AppModel.self) private var model
    @State private var pendingRemoval: AlertRule?

    var body: some View {
        @Bindable var model = model
        let ruleSet = model.settings.ruleSet
        NavigationStack {
            List {
                let issues = ruleSet.validate()
                if !issues.isEmpty {
                    Section {
                        ForEach(issues, id: \.self) { issue in
                            Label(describe(issue), systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                        }
                    }
                }

                ForEach(AlertDirection.allCases, id: \.self) { direction in
                    Section {
                        ForEach(ruleSet.rules(for: direction).sorted { $0.isMoreSevere(than: $1) }) { rule in
                            NavigationLink {
                                RuleEditorView(rule: rule)
                            } label: {
                                RuleRow(rule: rule, unit: model.unit)
                            }
                            .swipeActions {
                                Button("Delete", role: .destructive) { requestRemoval(rule) }
                                Button("Duplicate") { model.updateRules { try $0.duplicate(id: rule.id) } }
                            }
                        }
                        if ruleSet.rules(for: direction).count < AlertRuleSet.maxRulesPerDirection {
                            Button {
                                model.addRule(direction)
                            } label: {
                                Label("Add \(direction.rawValue) alert", systemImage: "plus")
                            }
                        }
                    } header: {
                        Text(direction == .low ? "Low alerts" : "High alerts")
                    } footer: {
                        Text("Up to \(AlertRuleSet.maxRulesPerDirection). When several are crossed, only the most severe sounds.")
                    }
                }

                Section {
                    ForEach(ruleSet.trendAlerts) { alert in
                        NavigationLink {
                            TrendAlertEditorView(alert: alert)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(alert.name)
                                    Text(trendDescription(alert)).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if !alert.isEnabled {
                                    Image(systemName: "bell.slash").foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Trend alerts")
                } footer: {
                    Text("Based on the last 15 minutes. \"Low soon\" stays quiet while a low alert is already sounding.")
                }

                Section {
                    Toggle("Alert when no data", isOn: $model.settings.missingData.isEnabled)
                    Stepper(value: $model.settings.missingData.minutes, in: MissingDataAlert.allowedMinutes, step: 5) {
                        Text("After \(model.settings.missingData.minutes) min without readings")
                    }
                    Toggle("Quiet during sensor warm-up", isOn: $model.settings.missingData.suppressDuringWarmUp)
                    SoundPicker(sound: $model.settings.missingData.sound)
                } header: {
                    Text("Missing data")
                } footer: {
                    Text("Scheduled ahead with iOS, so it still fires if the app has been closed.")
                }

                Section("Presets") {
                    Button("Basic (80 / 70 / 60, 180 / 220 / 250)") { model.updateRules { $0 = .basic() } }
                    Button("Night") { model.updateRules { $0 = .night() } }
                    Button("Sensitive") { model.updateRules { $0 = .sensitive() } }
                }
            }
            .navigationTitle("Alerts")
            .confirmationDialog("Remove your last urgent-low alert?", isPresented: Binding(
                get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }
            ), titleVisibility: .visible) {
                Button("Remove anyway", role: .destructive) {
                    if let rule = pendingRemoval { model.updateRules { $0.remove(id: rule.id) } }
                    pendingRemoval = nil
                }
            } message: {
                Text("Without an alert at or below \(model.unit.format(mgdL: AlertRuleSet.urgentLowMgdL, includeSymbol: true)), a dangerous low could go unnoticed.")
            }
        }
    }

    private func requestRemoval(_ rule: AlertRule) {
        let urgent = model.settings.ruleSet.urgentLowRules
        if urgent.count == 1, urgent.first?.id == rule.id {
            pendingRemoval = rule
        } else {
            model.updateRules { $0.remove(id: rule.id) }
        }
    }

    private func trendDescription(_ alert: TrendAlert) -> String {
        switch alert.kind {
        case .predictiveLow(let threshold, let minutes):
            return "Below \(model.unit.format(mgdL: threshold, includeSymbol: true)) within \(minutes) min"
        case .fallingFast(let rate):
            return "Falling faster than \(model.unit.format(mgdL: rate)) \(model.unit.symbol)/min"
        case .risingFast(let rate):
            return "Rising faster than \(model.unit.format(mgdL: rate)) \(model.unit.symbol)/min"
        }
    }

    private func describe(_ issue: AlertRuleSet.Issue) -> String {
        let unit = model.unit
        switch issue {
        case .duplicateThreshold(let direction, let value):
            return "Two \(direction.rawValue) alerts use \(unit.format(mgdL: value, includeSymbol: true))."
        case .lowAboveHigh(let low, let high):
            return "A low alert (\(unit.format(mgdL: low))) is at or above a high alert (\(unit.format(mgdL: high)))."
        case .noUrgentLow:
            return "No low alert at or below \(unit.format(mgdL: AlertRuleSet.urgentLowMgdL, includeSymbol: true))."
        case .noEnabledRules(let direction):
            return "No \(direction.rawValue) alerts are on."
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
                Text(details).font(.caption).foregroundStyle(.secondary)
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

    private var details: String {
        var parts = [SoundCatalog.title(for: rule.sound)]
        if rule.isCritical { parts.append("Critical") }
        if let minutes = rule.repeatIntervalMinutes { parts.append("repeat \(minutes) min") }
        if rule.schedule != .always { parts.append("scheduled") }
        return parts.joined(separator: " · ")
    }
}

/// Silent / tune / voice, with the file to play and a preview button.
struct SoundPicker: View {
    @Binding var sound: SoundStyle
    var direction: AlertDirection = .low

    private enum Kind: String, CaseIterable, Identifiable {
        case silent = "Silent", tune = "Tune", voice = "Voice"
        var id: String { rawValue }
    }

    var body: some View {
        Picker("Sound", selection: kind) {
            ForEach(Kind.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)

        if case .tune(let name) = sound {
            Picker("Tune", selection: Binding(get: { name }, set: { sound = .tune(name: $0) })) {
                ForEach(SoundCatalog.tunes + SoundCatalog.customTunes()) { Text($0.title).tag($0.id) }
            }
        }
        if case .voice(let clip) = sound {
            Picker("Voice", selection: Binding(get: { clip }, set: { sound = .voice(clip: $0) })) {
                ForEach(SoundCatalog.voiceClips) { Text($0.title).tag($0.id) }
            }
        }
        if sound != .silent {
            if SoundPreviewPlayer.shared.playing == sound {
                Button(role: .destructive) {
                    SoundPreviewPlayer.shared.stop()
                } label: {
                    Label("Stop", systemImage: "stop.circle.fill")
                }
            } else {
                Button {
                    SoundPreviewPlayer.shared.play(sound)
                } label: {
                    Label("Play", systemImage: "play.circle")
                }
            }
        }
    }

    private var kind: Binding<Kind> {
        Binding {
            switch sound {
            case .silent: return .silent
            case .tune: return .tune
            case .voice: return .voice
            }
        } set: { newKind in
            switch newKind {
            case .silent: sound = .silent
            case .tune: sound = .tune(name: direction == .low ? "alarm_loud_low" : "alarm_high")
            case .voice: sound = .voice(clip: direction == .low ? "glucose_low" : "glucose_high")
            }
        }
    }
}

struct RuleEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var rule: AlertRule
    @State private var confirmDisable = false

    init(rule: AlertRule) {
        _rule = State(initialValue: rule)
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
                Toggle("On", isOn: $rule.isEnabled)
                Stepper(value: $rule.thresholdMgdL, in: AlertRuleSet.thresholdRangeMgdL, step: unit.editorStepMgdL) {
                    Text("\(rule.direction == .low ? "Below" : "Above") \(unit.format(mgdL: rule.thresholdMgdL, includeSymbol: true))")
                }
            }

            Section("Sound") {
                SoundPicker(sound: $rule.sound, direction: rule.direction)
                Toggle("Critical Alert (sounds through Silent and Focus)", isOn: $rule.isCritical)
                if rule.isCritical {
                    Slider(value: $rule.criticalVolume, in: 0.1...1) { Text("Volume") }
                    Text(model.notifications.criticalAllowed
                         ? "Critical Alerts are allowed on this phone."
                         : "Needs Apple's Critical Alerts entitlement. Until then this is sent as Time Sensitive.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Timing") {
                Stepper(value: optionalMinutes(\.repeatIntervalMinutes), in: 0...120) {
                    Text(rule.repeatIntervalMinutes.map { "Repeat every \($0) min" } ?? "No repeat")
                }
                if rule.repeatIntervalMinutes != nil {
                    Stepper(value: optionalMinutes(\.maxRepeats), in: 0...20) {
                        Text(rule.maxRepeats.map { "Up to \($0) repeats" } ?? "Repeat until acknowledged")
                    }
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
                Button("Save") { save() }
            }
        }
        .confirmationDialog("Turn off your last urgent-low alert?", isPresented: $confirmDisable, titleVisibility: .visible) {
            Button("Save anyway", role: .destructive) { commit() }
        } message: {
            Text("Without an alert at or below \(unit.format(mgdL: AlertRuleSet.urgentLowMgdL, includeSymbol: true)), a dangerous low could go unnoticed.")
        }
        .onDisappear { SoundPreviewPlayer.shared.stop() }
    }

    private func save() {
        let urgent = model.settings.ruleSet.urgentLowRules
        let losesSafeguard = urgent.count == 1 && urgent.first?.id == rule.id
            && (!rule.isEnabled || rule.thresholdMgdL > AlertRuleSet.urgentLowMgdL)
        if losesSafeguard {
            confirmDisable = true
        } else {
            commit()
        }
    }

    private func commit() {
        model.updateRules { try $0.update(rule) }
        dismiss()
    }

    private var scheduleKind: Binding<ScheduleKind> {
        Binding {
            ScheduleKind.allCases.first { $0.schedule == rule.schedule } ?? .always
        } set: { kind in
            rule.schedule = kind.schedule
        }
    }

    /// Maps an optional minutes value to a stepper where 0 means "off".
    private func optionalMinutes(_ keyPath: WritableKeyPath<AlertRule, Int?>) -> Binding<Int> {
        Binding {
            rule[keyPath: keyPath] ?? 0
        } set: { value in
            rule[keyPath: keyPath] = value == 0 ? nil : value
        }
    }
}

struct TrendAlertEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var alert: TrendAlert

    init(alert: TrendAlert) {
        _alert = State(initialValue: alert)
    }

    var body: some View {
        let unit = model.unit
        Form {
            Section {
                Toggle("On", isOn: $alert.isEnabled)
                switch alert.kind {
                case .predictiveLow(let threshold, let minutes):
                    Stepper(value: Binding(get: { threshold }, set: { alert.kind = .predictiveLow(thresholdMgdL: $0, minutesAhead: minutes) }),
                            in: 50...120, step: unit.editorStepMgdL) {
                        Text("Below \(unit.format(mgdL: threshold, includeSymbol: true))")
                    }
                    Stepper(value: Binding(get: { minutes }, set: { alert.kind = .predictiveLow(thresholdMgdL: threshold, minutesAhead: $0) }),
                            in: 10...40, step: 5) {
                        Text("Within \(minutes) min")
                    }
                case .fallingFast(let rate):
                    Stepper(value: Binding(get: { rate }, set: { alert.kind = .fallingFast(mgdLPerMinute: $0) }), in: 1...5, step: 0.5) {
                        Text("Faster than \(String(format: "%.1f", rate)) mg/dL per min")
                    }
                case .risingFast(let rate):
                    Stepper(value: Binding(get: { rate }, set: { alert.kind = .risingFast(mgdLPerMinute: $0) }), in: 1...5, step: 0.5) {
                        Text("Faster than \(String(format: "%.1f", rate)) mg/dL per min")
                    }
                }
            }
            Section("Sound") {
                SoundPicker(sound: $alert.sound, direction: alert.kind.direction)
                Toggle("Critical Alert", isOn: $alert.isCritical)
                Stepper(value: $alert.snoozeMinutes, in: 5...240, step: 5) {
                    Text("Snooze \(alert.snoozeMinutes) min")
                }
            }
        }
        .navigationTitle(alert.name)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    model.updateRules { $0.updateTrendAlert(alert) }
                    dismiss()
                }
            }
        }
        .onDisappear { SoundPreviewPlayer.shared.stop() }
    }
}
