import SwiftUI
import Charts
import GlucoseCore

/// Builds report files in the temporary directory for the share sheet.
@MainActor
enum ReportExporter {
    static let pageSize = CGSize(width: 595, height: 842) // A4 in points

    static func pdf(stats: GlucoseStatistics, readings: [GlucoseReading], period: DateInterval, unit: GlucoseUnit) -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Glucose report \(fileDate(period.end)).pdf")
        let document = ReportDocument(stats: stats, profile: AmbulatoryGlucoseProfile(readings: readings), period: period, unit: unit)
            .frame(width: pageSize.width, height: pageSize.height)
        let renderer = ImageRenderer(content: document)
        var written = false
        renderer.render { _, render in
            var box = CGRect(origin: .zero, size: pageSize)
            guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else { return }
            context.beginPDFPage(nil)
            render(context)
            context.endPDFPage()
            context.closePDF()
            written = true
        }
        return written ? url : nil
    }

    /// One CSV per data type, combined in a folder-like single file with section headers.
    static func csvBundle(readings: [GlucoseReading], logbook: [LogEntry], fingersticks: [FingerstickEntry]) -> URL? {
        let text = "# Readings\n" + CSVExport.readings(readings)
            + "\n# Notes\n" + CSVExport.logbook(logbook)
            + "\n# Fingersticks\n" + CSVExport.fingersticks(fingersticks)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Glucose data \(fileDate(Date())).csv")
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    private static func fileDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

/// One-page summary for a doctor's visit.
struct ReportDocument: View {
    let stats: GlucoseStatistics
    let profile: AmbulatoryGlucoseProfile
    let period: DateInterval
    let unit: GlucoseUnit

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Glucose report").font(.title.bold())
                Text("\(period.start.formatted(date: .long, time: .omitted)) – \(period.end.formatted(date: .long, time: .omitted))")
                    .foregroundStyle(.secondary)
                Text("Personal CGM app, not a medical device. Values are calibrated against fingersticks.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                row("Time in range (70-180)", String(format: "%.0f %%", stats.ranges.inRange * 100), "> 70%")
                row("Below 70 / below 54", String(format: "%.1f %% / %.1f %%", stats.ranges.belowRange * 100, stats.ranges.veryLow * 100), "< 4% / < 1%")
                row("Above 180 / above 250", String(format: "%.0f %% / %.0f %%", stats.ranges.aboveRange * 100, stats.ranges.veryHigh * 100), "< 25% / < 5%")
                row("Mean glucose", unit.format(mgdL: stats.meanMgdL, includeSymbol: true), "")
                row("GMI", String(format: "%.1f %%", stats.gmiPercent), "")
                row("CV", String(format: "%.1f %%", stats.coefficientOfVariation), "≤ 36%")
                row("Sensor data", String(format: "%.0f %%", stats.dataSufficiency * 100), "> 70%")
            }
            .font(.callout)

            TimeInRangeBar(ranges: stats.ranges).frame(height: 24)

            Text("Ambulatory Glucose Profile").font(.headline)
            AGPChart(profile: profile, unit: unit).frame(height: 260)
            Spacer()
        }
        .padding(40)
        .background(Color.white)
        .environment(\.colorScheme, .light)
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String, _ target: String) -> some View {
        GridRow {
            Text(label)
            Text(value).bold().monospacedDigit()
            Text(target).foregroundStyle(.secondary)
        }
    }
}
