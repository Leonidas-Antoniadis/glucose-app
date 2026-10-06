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
                    SoundPicker(sound: $model.settings.missingData.sound, defaultTune: "chime", defaultVoice: "no_data")
                    Button("Send test alert", systemImage: "bell.badge") {
                        model.sendTestMissingDataAlert()
                    }
                } header: {
                    Text("Missing data")
                } footer: {
                    Text(model.settings.runInBackground
                         ? "Scheduled ahead with iOS, so it still fires if the app has been closed."
                         : "Off while the app is closed, because Run in background is off (Settings → Battery).")
                }

                Section("Presets") {
                    Button("Basic (\(basicThresholds))") { model.updateRules { $0 = $0.applyingPreset(.basic()) } }
                    Button("Night") { model.updateRules { $0 = $0.applyingPreset(.night()) } }
                    Button("Sensitive") { model.updateRules { $0 = $0.applyingPreset(.sensitive()) } }
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
            return "Falling faster than \(model.unit.formatRate(mgdLPerMinute: rate))"
        case .risingFast(let rate):
            return "Rising faster than \(model.unit.formatRate(mgdLPerMinute: rate))"
        }
    }

    /// The Basic preset's thresholds in the display unit, lows then highs.
    private var basicThresholds: String {
        let rules = AlertRuleSet.basic().rules
        let lows = rules.filter { $0.direction == .low }.map { model.unit.format(mgdL: $0.thresholdMgdL) }
        let highs = rules.filter { $0.direction == .high }.map { model.unit.format(mgdL: $0.thresholdMgdL) }
        return lows.joined(separator: " / ") + ", " + highs.joined(separator: " / ")
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
    /// What Tune and Voice switch to. Defaults to the low or high alarm and voice, which would be
    /// wrong for the missing-data alert (a data gap must not announce "Glucose low").
    var defaultTune: String? = nil
    var defaultVoice: String? = nil

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
            // A separate list: the long titles don't fit beside the label in a menu picker.
            .pickerStyle(.navigationLink)
            if SoundCatalog.isMissing(sound) {
                Text("This imported tune isn't on this phone (for example after restoring a backup), so the built-in alarm plays instead. Import it again or pick another tune.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        if case .voice(let clip) = sound {
            Picker("Voice", selection: Binding(get: { clip }, set: { sound = .voice(clip: $0) })) {
                ForEach(SoundCatalog.voiceClips) { Text($0.title).tag($0.id) }
            }
            .pickerStyle(.navigationLink)
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
            case .tune: sound = .tune(name: defaultTune ?? (direction == .low ? "alarm_loud_low" : "alarm_high"))
            case .voice: sound = .voice(clip: defaultVoice ?? (direction == .low ? "glucose_low" : "glucose_high"))
            }
        }
    }
}

struct RuleEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var rule: AlertRule
    @State private var confirmDisable = false
    /// As it was when the editor opened: with changes, Back is replaced by Cancel and Save, so
    /// an edit can't be lost by going back.
    private let original: AlertRule

    init(rule: AlertRule) {
        _rule = State(initialValue: rule)
        original = rule
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
                GlucoseValuePicker(title: rule.direction == .low ? "Alert below" : "Alert above",
                                   mgdL: $rule.thresholdMgdL,
                                   range: AlertRuleSet.thresholdRangeMgdL,
                                   unit: unit)
                if rule.confirmationMinutes > 0 {
                    Text("Waits until glucose has stayed past this for \(rule.confirmationMinutes) min. Change it under Timing.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Sound") {
                SoundPicker(sound: $rule.sound, direction: rule.direction)
                if rule.sound == .silent && !rule.isCritical {
                    Text("Silent: shows a notification without any sound. Pick Tune or Voice to hear it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Toggle("Sound through Silent mode and Focus", isOn: criticalBinding)
                if rule.isCritical {
                    CriticalAlertsChecklist()
                    if model.criticalAlertsAllowed {
                        Slider(value: $rule.criticalVolume, in: 0.1...1) { Text("Volume") }
                    }
                }
                Button("Send test alert", systemImage: "bell.badge") {
                    model.sendTestAlert(for: rule)
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
        .navigationBarBackButtonHidden(rule != original)
        .toolbar {
            if rule != original {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }
            }
        }
        .confirmationDialog("Change your last all-day urgent-low alert?", isPresented: $confirmDisable, titleVisibility: .visible) {
            Button("Save anyway", role: .destructive) { commit() }
        } message: {
            Text("Without an alert at or below \(unit.format(mgdL: AlertRuleSet.urgentLowMgdL, includeSymbol: true)) that is on all day, a dangerous low could go unnoticed.")
        }
        .onDisappear { SoundPreviewPlayer.shared.stop() }
    }

    private func save() {
        let urgent = model.settings.ruleSet.urgentLowRules
        let losesSafeguard = urgent.count == 1 && urgent.first?.id == rule.id
            && (!rule.isEnabled || rule.thresholdMgdL > AlertRuleSet.urgentLowMgdL || rule.schedule != .always)
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

    /// Turning on "through Silent and Focus" gives a silent rule a tune, since it has to make a sound.
    private var criticalBinding: Binding<Bool> {
        Binding {
            rule.isCritical
        } set: { on in
            rule.isCritical = on
            if on, rule.sound == .silent {
                rule.sound = .tune(name: rule.direction == .low ? "alarm_loud_low" : "alarm_high")
            }
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
    private let original: TrendAlert

    init(alert: TrendAlert) {
        _alert = State(initialValue: alert)
        original = alert
    }

    var body: some View {
        let unit = model.unit
        Form {
            Section {
                Toggle("On", isOn: $alert.isEnabled)
                switch alert.kind {
                case .predictiveLow(let threshold, let minutes):
                    GlucoseValuePicker(title: "Below",
                                       mgdL: Binding(get: { threshold }, set: { alert.kind = .predictiveLow(thresholdMgdL: $0, minutesAhead: minutes) }),
                                       range: 50...120, unit: unit)
                    Stepper(value: Binding(get: { minutes }, set: { alert.kind = .predictiveLow(thresholdMgdL: threshold, minutesAhead: $0) }),
                            in: 10...40, step: 5) {
                        Text("Within \(minutes) min")
                    }
                case .fallingFast(let rate):
                    Stepper(value: Binding(get: { rate }, set: { alert.kind = .fallingFast(mgdLPerMinute: $0) }), in: 1...5, step: 0.5) {
                        Text("Faster than \(unit.formatRate(mgdLPerMinute: rate))")
                    }
                case .risingFast(let rate):
                    Stepper(value: Binding(get: { rate }, set: { alert.kind = .risingFast(mgdLPerMinute: $0) }), in: 1...5, step: 0.5) {
                        Text("Faster than \(unit.formatRate(mgdLPerMinute: rate))")
                    }
                }
            }
            Section("Sound") {
                SoundPicker(sound: $alert.sound, direction: alert.kind.direction)
                Toggle("Sound through Silent mode and Focus", isOn: $alert.isCritical)
                if alert.isCritical {
                    CriticalAlertsChecklist()
                }
                Stepper(value: $alert.snoozeMinutes, in: 5...240, step: 5) {
                    Text("Snooze \(alert.snoozeMinutes) min")
                }
                Button("Send test alert", systemImage: "bell.badge") {
                    model.sendTestAlert(for: alert)
                }
            }
        }
        .navigationTitle(alert.name)
        .navigationBarBackButtonHidden(alert != original)
        .toolbar {
            if alert != original {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
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
