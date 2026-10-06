import SwiftUI
import UniformTypeIdentifiers
import GlucoseCore

/// Accuracy as more than one number: the average error with its range, the bias in plain
/// words, a consensus error grid, and where the sensor is weaker.
struct AccuracyView: View {
    @Environment(AppModel.self) private var model
    @State private var report: AccuracyReport?

    var body: some View {
        List {
            if let report {
                if let mard = report.mard {
                    summary(report, mard: mard)
                    errorGrid(report)
                    breakdown(report, overall: mard)
                } else {
                    ContentUnavailableView {
                        Label("No checks yet", systemImage: "drop")
                    } description: {
                        Text(model.isDemo
                             ? "Accuracy is measured against your own sensor, so it isn't shown for the demo."
                             : "Add a fingerstick without \"Use to calibrate\". Each one is compared with the sensor value at that moment. Type what LibreLink showed too, to compare the two apps.")
                    }
                }
            } else {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            }
        }
        .navigationTitle("Accuracy")
        .toolbar {
            if let report, !report.pairs.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: AccuracyCSV(report: report), preview: SharePreview("Glucose accuracy.csv")) {
                        Label("Export accuracy data", systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
        .task(id: model.fingersticks.count) {
            report = await model.fullAccuracyReport()
        }
    }

    // MARK: Sections

    @ViewBuilder
    private func summary(_ report: AccuracyReport, mard: Double) -> some View {
        let u = model.unit
        Section {
            VStack(alignment: .leading, spacing: 2) {
                Text("Average error vs meter (MARD)").font(.caption).foregroundStyle(.secondary)
                Text(String(format: "%.1f %%", mard))
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text(summaryLine(report)).font(.caption).foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)
            if let within = report.within15_15 {
                MetricRow(label: "Within \(u.format(mgdL: 15, includeSymbol: true)) or 15 %",
                          value: String(format: "%.0f %%", within * 100))
            }
            if let within = report.within20_20 {
                MetricRow(label: "Within \(u.format(mgdL: 20, includeSymbol: true)) or 20 %",
                          value: String(format: "%.0f %%", within * 100))
            }
            if let bias = report.biasMgdL {
                MetricRow(label: "Bias", value: biasText(bias))
            }
            if let comparison = report.libreLinkComparison {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Compared with LibreLink")
                    HStack {
                        Text(String(format: "LibreLink %.1f %%", comparison.libreLink))
                        Text("·")
                        Text(String(format: "this app %.1f %%", comparison.app))
                            .fontWeight(comparison.app <= comparison.libreLink ? .semibold : .regular)
                    }
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    Text("On the same \(comparison.count) check\(comparison.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
        } footer: {
            Text("Only fingersticks not used for calibration count: a calibration point always matches.")
        }
    }

    @ViewBuilder
    private func errorGrid(_ report: AccuracyReport) -> some View {
        let counts = report.zoneCounts
        let total = Double(report.pairs.count)
        let share = { (zones: [ErrorGridZone]) in Double(zones.reduce(0) { $0 + (counts[$1] ?? 0) }) / total * 100 }
        Section {
            VStack(alignment: .leading, spacing: 8) {
                ErrorGridView(pairs: report.pairs, unit: model.unit)
                    .frame(height: 300)
                    .accessibilityElement()
                    .accessibilityLabel(String(format: "Consensus error grid: %.0f percent of checks in zone A, %.0f percent in B, %.0f percent in C to E.",
                                               share([.a]), share([.b]), share([.c, .d, .e])))
                HStack(spacing: 12) {
                    legend(.a, String(format: "A %.0f %%", share([.a])))
                    legend(.b, String(format: "B %.0f %%", share([.b])))
                    legend(.c, String(format: "C–E %.0f %%", share([.c, .d, .e])))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        } header: {
            Text("Error grid (consensus, type 1)")
        } footer: {
            Text("Meter across, this app up. Zone A: the error wouldn't change treatment. B: little or no effect. C and beyond: it could lead to a wrong decision.")
        }
    }

    @ViewBuilder
    private func breakdown(_ report: AccuracyReport, overall: Double) -> some View {
        let u = model.unit
        Section {
            ForEach(AccuracyReport.Group.allCases, id: \.self) { group in
                BreakdownRow(title: title(group, unit: u), subtitle: subtitle(group, unit: u),
                             summary: report.summary(group), overall: overall)
            }
        } header: {
            Text("Where it's less accurate")
        } footer: {
            Text("Meters are themselves about ±15 % accurate. Zones describe the size of errors; they are not a medical validation.")
        }
    }

    // MARK: Text

    private func summaryLine(_ report: AccuracyReport) -> String {
        var parts: [String] = []
        if let interval = report.mardInterval {
            parts.append(String(format: "95%% range %.1f–%.1f %%", interval.lowerBound, interval.upperBound))
        }
        parts.append("\(report.pairs.count) check\(report.pairs.count == 1 ? "" : "s")")
        if let range = report.dateRange {
            let start = range.lowerBound.formatted(.dateTime.month(.abbreviated).day())
            let end = range.upperBound.formatted(.dateTime.month(.abbreviated).day())
            parts.append(start == end ? start : "\(start) – \(end)")
        }
        return parts.joined(separator: " · ")
    }

    private func biasText(_ bias: Double) -> String {
        let size = model.unit.format(mgdL: abs(bias), includeSymbol: true)
        if abs(bias) < 2 { return "no clear offset" }
        return bias < 0 ? "reads \(size) low" : "reads \(size) high"
    }

    private func title(_ group: AccuracyReport.Group, unit u: GlucoseUnit) -> String {
        switch group {
        case .belowRange: return "Below \(u.format(mgdL: 70))"
        case .inRange: return "\(u.format(mgdL: 70))–\(u.format(mgdL: 180))"
        case .aboveRange: return "Above \(u.format(mgdL: 180))"
        case .firstDay: return "Sensor day 1"
        case .laterDays: return "Days 2–15"
        case .steady: return "Steady"
        case .moving: return "Moving"
        case .fast: return "Changing fast"
        }
    }

    private func subtitle(_ group: AccuracyReport.Group, unit u: GlucoseUnit) -> String? {
        switch group {
        case .steady: return "under \(u.formatRate(mgdLPerMinute: 1))"
        case .moving: return "\(u.formatRate(mgdLPerMinute: 1)) to \(u.formatRate(mgdLPerMinute: 2))"
        case .fast: return "over \(u.formatRate(mgdLPerMinute: 2))"
        default: return nil
        }
    }

    private func legend(_ zone: ErrorGridZone, _ text: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2)
                .fill(ErrorGridView.fill(zone))
                .overlay(RoundedRectangle(cornerRadius: 2).stroke(ErrorGridView.dot(zone), lineWidth: 1))
                .frame(width: 10, height: 10)
            Text(text).monospacedDigit()
        }
    }

}

/// The checks as a CSV file, written only when the user shares it.
private struct AccuracyCSV: Transferable {
    let report: AccuracyReport

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .commaSeparatedText) { csv in
            let url = AppStores.exportsDirectory.appendingPathComponent("Glucose accuracy.csv")
            try csv.report.csv().write(to: url, atomically: true, encoding: .utf8)
            return SentTransferredFile(url)
        }
    }
}

/// One condition: its MARD as a bar, with how many checks it rests on.
private struct BreakdownRow: View {
    let title: String
    let subtitle: String?
    let summary: AccuracyReport.Summary?
    let overall: Double

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(title)
                    if let summary, summary.isTooFew {
                        Text("too few")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.15), in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                }
                if let subtitle {
                    Text(subtitle).font(.caption2).foregroundStyle(.secondary)
                }
            }
            .frame(width: 150, alignment: .leading)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.12))
                    if let summary {
                        Capsule().fill(color(summary))
                            .frame(width: proxy.size.width * min(summary.mard / 30, 1))
                    }
                }
            }
            .frame(height: 8)
            Text(summary.map { String(format: "%.1f %% · n=%d", $0.mard, $0.count) } ?? "no checks")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .trailing)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(summary.map { String(format: "%@: %.1f percent from %d checks", title, $0.mard, $0.count) } ?? "\(title): no checks")
    }

    /// Orange where it's clearly worse than overall, grey where there are too few checks to tell.
    private func color(_ summary: AccuracyReport.Summary) -> Color {
        if summary.isTooFew { return .secondary.opacity(0.5) }
        return summary.mard > overall * 1.25 ? .orange : .accentColor
    }
}

/// The consensus error grid with the checks as dots, drawn up to 400 mg/dL.
struct ErrorGridView: View {
    let pairs: [AccuracyReport.Pair]
    let unit: GlucoseUnit
    private let maxValue = 400.0

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 4) {
                Text("This app")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .rotationEffect(.degrees(-90))
                    .frame(width: 12)
                Canvas { context, size in draw(in: &context, size: size) }
            }
            Text("Meter").font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let plot = CGRect(x: 30, y: 6, width: max(0, size.width - 38), height: max(0, size.height - 26))
        func point(_ x: Double, _ y: Double) -> CGPoint {
            CGPoint(x: plot.minX + x / maxValue * plot.width, y: plot.maxY - y / maxValue * plot.height)
        }

        context.drawLayer { layer in
            layer.clip(to: Path(plot))
            layer.fill(Path(plot), with: .color(Self.background))
            layer.fill(Path(plot), with: .color(Self.fill(.e)))
            // Outermost region first; each inner one is painted over it.
            for boundary in ParkesErrorGrid.boundaries.reversed() {
                let region = regionPath(boundary, point: point)
                layer.fill(region, with: .color(Self.background))
                layer.fill(region, with: .color(Self.fill(boundary.inner)))
            }
            var diagonal = Path()
            diagonal.move(to: point(0, 0))
            diagonal.addLine(to: point(maxValue, maxValue))
            layer.stroke(diagonal, with: .color(.secondary), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            for pair in pairs {
                let center = point(min(pair.referenceMgdL, maxValue), min(pair.sensorMgdL, maxValue))
                let dot = Path(ellipseIn: CGRect(x: center.x - 3.5, y: center.y - 3.5, width: 7, height: 7))
                layer.fill(dot, with: .color(Self.dot(pair.zone)))
                layer.stroke(dot, with: .color(Self.background), lineWidth: 1)
            }
        }
        context.stroke(Path(plot), with: .color(.secondary.opacity(0.4)), lineWidth: 0.75)

        for tick in [100.0, 200, 300, 400] {
            let label = Text(unit.format(mgdL: tick)).font(.caption2).foregroundColor(.secondary)
            context.draw(label, at: CGPoint(x: plot.minX - 4, y: point(0, tick).y), anchor: .trailing)
            // The last label ends at the edge instead of running past it.
            context.draw(label, at: CGPoint(x: point(tick, 0).x, y: plot.maxY + 3), anchor: tick == maxValue ? .topTrailing : .top)
            var grid = Path()
            grid.move(to: point(tick, 0))
            grid.addLine(to: point(tick, maxValue))
            grid.move(to: point(0, tick))
            grid.addLine(to: point(maxValue, tick))
            context.stroke(grid, with: .color(.secondary.opacity(0.15)), lineWidth: 0.5)
        }
        let zoneLabels: [(ErrorGridZone, Double, Double)] = [
            (.a, 360, 380), (.b, 200, 385), (.b, 385, 250), (.c, 120, 385), (.c, 385, 130), (.d, 70, 385), (.d, 385, 30), (.e, 15, 385),
        ]
        for (zone, x, y) in zoneLabels {
            context.draw(Text(zone.rawValue).font(.caption2.bold()).foregroundColor(.secondary), at: point(x, y))
        }
    }

    /// The area inside a boundary: under its upper line and over its lower one.
    private func regionPath(_ boundary: ParkesErrorGrid.Boundary, point: (Double, Double) -> CGPoint) -> Path {
        let far = 2_000.0
        var path = Path()
        path.move(to: point(0, 0))
        for vertex in boundary.upper { path.addLine(to: point(vertex.x, vertex.y)) }
        path.addLine(to: point(far, ParkesErrorGrid.value(of: boundary.upper, at: far) ?? far))
        if let lower = boundary.lower {
            path.addLine(to: point(far, ParkesErrorGrid.value(of: lower, at: far) ?? 0))
            for vertex in lower.reversed() { path.addLine(to: point(vertex.x, vertex.y)) }
        } else {
            path.addLine(to: point(far, 0))
        }
        path.closeSubpath()
        return path
    }

    static let background = Color(uiColor: .secondarySystemGroupedBackground)

    static func fill(_ zone: ErrorGridZone) -> Color {
        switch zone {
        case .a: return .green.opacity(0.16)
        case .b: return .yellow.opacity(0.22)
        case .c: return .orange.opacity(0.18)
        case .d: return .orange.opacity(0.3)
        case .e: return .red.opacity(0.18)
        }
    }

    static func dot(_ zone: ErrorGridZone) -> Color {
        switch zone {
        case .a: return .blue
        case .b: return .orange
        default: return .red
        }
    }
}
