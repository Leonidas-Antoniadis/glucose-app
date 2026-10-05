import SwiftUI
import Charts
import GlucoseCore

enum RangeColor {
    static func color(for mgdL: Double) -> Color {
        switch mgdL {
        case ..<54: return .red
        case ..<70: return .orange
        case ...180: return .green
        case ...250: return .yellow
        default: return .orange
        }
    }
}

/// Glucose line with the 70-180 target band, logbook markers and tap-to-inspect.
struct GlucoseChart: View {
    let readings: [GlucoseReading]
    let unit: GlucoseUnit
    var entries: [LogEntry] = []
    @State private var selectedDate: Date?

    var body: some View {
        let start = readings.first?.timestamp ?? Date()
        let end = readings.last?.timestamp ?? Date()
        let maxValue = max(300, readings.map(\.mgdL).max() ?? 0)
        let visibleEntries = entries.filter { $0.date >= start && $0.date <= end }

        Chart {
            RectangleMark(
                xStart: .value("Start", start),
                xEnd: .value("End", end),
                yStart: .value("Target low", unit.fromMgdL(70)),
                yEnd: .value("Target high", unit.fromMgdL(180))
            )
            .foregroundStyle(.green.opacity(0.12))

            ForEach(readings) { reading in
                LineMark(
                    x: .value("Time", reading.timestamp),
                    y: .value("Glucose", unit.fromMgdL(reading.mgdL))
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(.primary)
            }

            ForEach(visibleEntries) { entry in
                PointMark(
                    x: .value("Time", entry.date),
                    y: .value("Note", unit.fromMgdL(maxValue))
                )
                .symbol {
                    Image(systemName: entry.symbolName)
                        .font(.caption2)
                        .foregroundStyle(.blue)
                }
            }

            if let selectedDate, let nearest = nearest(to: selectedDate) {
                RuleMark(x: .value("Selected", nearest.timestamp))
                    .foregroundStyle(.gray.opacity(0.5))
                    .annotation(position: .top, spacing: 4,
                                overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        VStack(spacing: 2) {
                            Text(unit.format(mgdL: nearest.mgdL, includeSymbol: true)).font(.caption.bold())
                            Text(nearest.timestamp, style: .time).font(.caption2).foregroundStyle(.secondary)
                        }
                        .padding(6)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 6))
                    }
            }
        }
        .chartYScale(domain: unit.fromMgdL(40)...unit.fromMgdL(maxValue))
        .chartXSelection(value: $selectedDate)
        .accessibilityLabel("Glucose chart")
    }

    private func nearest(to date: Date) -> GlucoseReading? {
        readings.min { abs($0.timestamp.timeIntervalSince(date)) < abs($1.timestamp.timeIntervalSince(date)) }
    }
}

struct MetricRow: View {
    let label: String
    let value: String
    var warning = false

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            if warning {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            Text(value).monospacedDigit().foregroundStyle(.secondary)
        }
    }
}

struct Banner: View {
    let systemImage: String
    let text: String
    var color: Color = .orange

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.subheadline)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
    }
}

extension GlucoseUnit {
    /// Parses user input in this unit into mg/dL.
    func parse(_ text: String) -> Double? {
        let normalized = text.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)
        guard let value = Double(normalized), value > 0 else { return nil }
        return toMgdL(value)
    }
}
