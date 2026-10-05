import SwiftUI
import UIKit
import GlucoseCore

/// Opens this app's page in iOS Settings → Notifications, where Critical Alerts are allowed.
private func openNotificationSettings(_ openURL: OpenURLAction) {
    if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
        openURL(url)
    }
}

/// The home screen's list of alerts marked Critical. Tapping it opens iOS Settings.
struct CriticalAlertsCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL

    var body: some View {
        let rules = model.settings.ruleSet.rules
            .filter { $0.isEnabled && $0.isCritical }
            .sorted { $0.thresholdMgdL < $1.thresholdMgdL }
        if !rules.isEmpty {
            Button {
                openNotificationSettings(openURL)
            } label: {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label("Critical alerts", systemImage: "exclamationmark.triangle.fill")
                            .font(.headline)
                        Spacer()
                        Image(systemName: "gear").foregroundStyle(.secondary)
                    }
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
                    if model.criticalAlertsAllowed {
                        Label("These sound through Silent mode and Focus.", systemImage: "checkmark.shield.fill")
                            .font(.footnote)
                            .foregroundStyle(.green)
                    } else {
                        Label("iOS isn't letting these through Silent mode and Focus yet. Tap to open Settings.",
                              systemImage: "exclamationmark.shield.fill")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
                .contentShape(RoundedRectangle(cornerRadius: 16))
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens notification settings")
        }
    }
}

/// Whether Critical Alerts are allowed, with a button to iOS Settings. Used in the alert editors.
struct CriticalAlertsStatus: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL

    var body: some View {
        Text(model.criticalAlertsAllowed
             ? "Critical Alerts are allowed on this phone."
             : "iOS hasn't allowed Critical Alerts for this app yet, so this is sent as Time Sensitive. The Critical Alerts switch appears in Settings once Apple approves it for the app.")
            .font(.caption)
            .foregroundStyle(.secondary)
        Button("Open notification settings", systemImage: "gear") {
            openNotificationSettings(openURL)
        }
    }
}
