import SwiftUI
import Charts
import GlucoseCore

/// A 2-hour chart attached to alert notifications, so a slow slide and a sudden drop look
/// different without unlocking the phone.
@MainActor
enum AlertChartRenderer {
    static let size = CGSize(width: 330, height: 150)

    /// Renders the chart to a PNG file for a notification attachment (iOS moves the file into its
    /// own store). Nil with too few readings to draw a line.
    static func render(readings: [GlucoseReading], unit: GlucoseUnit, threshold: Double?) -> URL? {
        guard readings.count >= 2 else { return nil }
        let renderer = ImageRenderer(content: AlertChartImage(readings: readings, unit: unit, threshold: threshold)
            .frame(width: size.width, height: size.height))
        renderer.scale = 3
        guard let data = renderer.uiImage?.pngData() else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("alert-chart-\(UUID().uuidString).png")
        do {
            try data.write(to: url)
            return url
        } catch {
            return nil
        }
    }
}

/// Dark, like the Lock Screen: the target range, the alert's threshold and the last 2 hours.
struct AlertChartImage: View {
    let readings: [GlucoseReading]
    let unit: GlucoseUnit
    let threshold: Double?

    var body: some View {
        let start = readings.first?.timestamp ?? Date()
        let end = readings.last?.timestamp ?? Date()
        let values = readings.map(\.mgdL) + [threshold].compactMap { $0 }
        let low = max(30, (values.min() ?? 70) - 15)
        let high = max(200, (values.max() ?? 180) + 15)
        let lineColor = RangePalette.color(mgdL: readings.last?.mgdL ?? 100)
        Chart {
            RectangleMark(xStart: .value("Start", start), xEnd: .value("End", end),
                          yStart: .value("Low", unit.fromMgdL(70)), yEnd: .value("High", unit.fromMgdL(180)))
                .foregroundStyle(Color.green.opacity(0.14))
            if let threshold {
                RuleMark(y: .value("Alert", unit.fromMgdL(threshold)))
                    .foregroundStyle(Color.orange)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    .annotation(position: .top, alignment: .trailing) {
                        Text(unit.format(mgdL: threshold)).font(.caption2.bold()).foregroundStyle(Color.orange)
                    }
            }
            ForEach(readings) { reading in
                LineMark(x: .value("Time", reading.timestamp), y: .value("Glucose", unit.fromMgdL(reading.mgdL)))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(lineColor)
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
            }
            if let last = readings.last {
                PointMark(x: .value("Time", last.timestamp), y: .value("Glucose", unit.fromMgdL(last.mgdL)))
                    .foregroundStyle(lineColor)
                    .symbolSize(60)
            }
        }
        .chartYScale(domain: unit.fromMgdL(low)...unit.fromMgdL(high))
        .chartXAxis {
            AxisMarks(values: .stride(by: .minute, count: 30)) { _ in
                AxisGridLine().foregroundStyle(Color.white.opacity(0.15))
                AxisValueLabel(format: .dateTime.hour().minute()).foregroundStyle(Color.white.opacity(0.6))
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: [70.0, 180].map { unit.fromMgdL($0) }) { _ in
                AxisValueLabel().foregroundStyle(Color.white.opacity(0.6))
            }
        }
        .padding(10)
        .background(Color(white: 0.11))
        .environment(\.colorScheme, .dark)
    }
}
