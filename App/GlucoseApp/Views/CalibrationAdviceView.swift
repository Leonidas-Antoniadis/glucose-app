import SwiftUI
import GlucoseCore

/// The calibration advice in the blood glucose form: what to do, why, and a button to follow it.
struct CalibrationAdviceView: View {
    let advice: CalibrationAdvice
    @Binding var calibrate: Bool

    var body: some View {
        let passed = advice.factors.filter { $0.status == .ok }
        VStack(alignment: .leading, spacing: 10) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(advice.title).font(.headline)
                    Text(advice.summary).font(.subheadline).foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: Self.symbol(advice.verdict)).foregroundStyle(Self.color(advice.verdict))
            }
            .accessibilityElement(children: .combine)
            ForEach(advice.factors.filter { $0.status != .ok }) { factor in
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(factor.title).font(.subheadline.weight(factor.status == .info ? .regular : .semibold))
                        if !factor.detail.isEmpty {
                            Text(factor.detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } icon: {
                    Image(systemName: Self.symbol(factor.status)).foregroundStyle(Self.color(factor.status))
                }
                .accessibilityElement(children: .combine)
            }
            // What's fine folds into one line.
            if !passed.isEmpty {
                Label {
                    Text(passed.map(\.title).joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(RangePalette.color(zone: 2))
                }
                .accessibilityElement(children: .combine)
            }
            if let recommended = advice.recommendsCalibrating, recommended != calibrate {
                Button(recommended ? "Turn on Use to calibrate" : "Turn off Use to calibrate") { calibrate = recommended }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }

    static func symbol(_ verdict: CalibrationAdvice.Verdict) -> String {
        switch verdict {
        case .calibrate: return "checkmark.seal.fill"
        case .notNeeded: return "hand.thumbsup.fill"
        case .checkAgain: return "repeat.circle.fill"
        case .wait: return "hourglass"
        case .testAgain: return "arrow.clockwise.circle.fill"
        case .cannot: return "xmark.circle.fill"
        }
    }

    static func color(_ verdict: CalibrationAdvice.Verdict) -> Color {
        switch verdict {
        case .calibrate, .notNeeded: return RangePalette.color(zone: 2)
        case .checkAgain, .wait, .testAgain: return RangePalette.warningText
        case .cannot: return .secondary
        }
    }

    private static func symbol(_ status: CalibrationAdvice.Factor.Status) -> String {
        switch status {
        case .problem: return "exclamationmark.triangle.fill"
        case .warning: return "exclamationmark.circle.fill"
        case .ok: return "checkmark.circle.fill"
        case .info: return "info.circle"
        }
    }

    private static func color(_ status: CalibrationAdvice.Factor.Status) -> Color {
        switch status {
        case .problem: return RangePalette.color(zone: 0)
        case .warning: return RangePalette.warningText
        case .ok: return RangePalette.color(zone: 2)
        case .info: return .secondary
        }
    }
}
