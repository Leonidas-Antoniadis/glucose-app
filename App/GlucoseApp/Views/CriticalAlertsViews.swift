import SwiftUI
import UIKit
import GlucoseCore

/// Opens this app's page in iOS Settings → Notifications (Time Sensitive and Critical Alerts switches).
func openNotificationSettings(_ openURL: OpenURLAction) {
    if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
        openURL(url)
    }
}

/// The home screen's list of alerts marked Critical, with what they need to break through.
struct CriticalAlertsCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let rules = model.settings.ruleSet.rules
            .filter { $0.isEnabled && $0.isCritical }
            .sorted { $0.thresholdMgdL < $1.thresholdMgdL }
        if !rules.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Label("Critical alerts", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                ForEach(rules) { rule in
                    HStack {
                        Image(systemName: rule.direction == .low ? "arrow.down.to.line" : "arrow.up.to.line")
                            .foregroundStyle(rule.direction == .low ? Color.red : Color.orange)
                            .frame(width: 24)
                        Text(rule.name)
                        Spacer()
                        Text("\(rule.direction == .low ? "<" : ">") \(model.unit.format(mgdL: rule.thresholdMgdL, includeSymbol: true))")
                            .monospacedDigit()
                    }
                    .font(.subheadline)
                }
                Divider()
                CriticalAlertsChecklist()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
    }
}

/// What lets an alert sound through Silent mode and Focus, with a button for each missing step.
/// No Apple approval is needed: the app plays the alarm itself (ignores the Silent switch),
/// and Time Sensitive notifications show during Focus.
struct CriticalAlertsChecklist: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.criticalAlertsAllowed {
                row(ok: true, title: "Critical Alerts allowed",
                    detail: "Alerts sound through Silent mode and Focus.")
            } else {
                row(ok: model.settings.runInBackground, title: "Silent mode",
                    detail: model.settings.runInBackground
                        ? "The app plays the alarm itself, even on Silent, at your media volume."
                        : "Turn on Run in background so the app can play the alarm while closed.") {
                    Button("Turn on") { model.settings.runInBackground = true }
                }
                row(ok: model.timeSensitiveAllowed, title: "Focus",
                    detail: model.timeSensitiveAllowed
                        ? "Time Sensitive notifications are on, so alerts show during Focus."
                        : "In Settings, turn on Time Sensitive Notifications.") {
                    Button("Open Settings") { openNotificationSettings(openURL) }
                }
            }
        }
    }

    private func row(ok: Bool, title: String, detail: String) -> some View {
        row(ok: ok, title: title, detail: detail) { EmptyView() }
    }

    private func row<Action: View>(ok: Bool, title: String, detail: String,
                                   @ViewBuilder action: () -> Action) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(ok ? .green : .orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
                if !ok {
                    action()
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .controlSize(.small)
                        .tint(.orange)
                }
            }
        }
    }
}
