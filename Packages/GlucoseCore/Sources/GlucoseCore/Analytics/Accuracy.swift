import Foundation

/// Sensor accuracy against fingersticks that were *not* used for calibration.
public struct AccuracyReport: Hashable, Sendable {
    /// One fingerstick and the sensor value closest to it.
    public struct Pair: Hashable, Sendable {
        public let date: Date
        public let referenceMgdL: Double
        public let sensorMgdL: Double
        /// What LibreLink showed at the same moment, if it was typed in.
        public let libreLinkMgdL: Double?
        public let sensorSerial: String?
        /// Day of wear: 1 for the sensor's first 24 hours.
        public let sensorDay: Int?
        /// How fast glucose was moving at the time, in mg/dL per minute.
        public let ratePerMinute: Double?

        public init(date: Date, referenceMgdL: Double, sensorMgdL: Double, libreLinkMgdL: Double? = nil,
                    sensorSerial: String? = nil, sensorDay: Int? = nil, ratePerMinute: Double? = nil) {
            self.date = date
            self.referenceMgdL = referenceMgdL
            self.sensorMgdL = sensorMgdL
            self.libreLinkMgdL = libreLinkMgdL
            self.sensorSerial = sensorSerial
            self.sensorDay = sensorDay
            self.ratePerMinute = ratePerMinute
        }

        /// Sensor minus meter, in mg/dL: negative when the sensor reads low.
        public var difference: Double { sensorMgdL - referenceMgdL }

        public var absoluteRelativeDifference: Double {
            abs(sensorMgdL - referenceMgdL) / referenceMgdL
        }

        /// ISO 15197-style band: within 15 mg/dL below 100 mg/dL, within 15% at or above.
        public var isWithin15_15: Bool {
            referenceMgdL < 100 ? abs(difference) <= 15 : absoluteRelativeDifference <= 0.15
        }

        /// The wider band CGM studies also report: 20 mg/dL below 100, 20% at or above.
        public var isWithin20_20: Bool {
            referenceMgdL < 100 ? abs(difference) <= 20 : absoluteRelativeDifference <= 0.20
        }

        public var zone: ErrorGridZone {
            ParkesErrorGrid.zone(referenceMgdL: referenceMgdL, sensorMgdL: sensorMgdL)
        }
    }

    /// Conditions the accuracy is broken down by.
    public enum Group: String, CaseIterable, Sendable {
        case belowRange, inRange, aboveRange, firstDay, laterDays, steady, moving, fast

        func contains(_ pair: Pair) -> Bool {
            switch self {
            case .belowRange: return pair.referenceMgdL < 70
            case .inRange: return (70...180).contains(pair.referenceMgdL)
            case .aboveRange: return pair.referenceMgdL > 180
            case .firstDay: return pair.sensorDay == 1
            case .laterDays: return (pair.sensorDay ?? 0) >= 2
            case .steady: return pair.ratePerMinute.map { abs($0) < 1 } ?? false
            case .moving: return pair.ratePerMinute.map { (1...2).contains(abs($0)) } ?? false
            case .fast: return pair.ratePerMinute.map { abs($0) > 2 } ?? false
            }
        }
    }

    /// MARD (percent) over a set of checks.
    public struct Summary: Hashable, Sendable {
        public let mard: Double
        public let count: Int
        /// Fewer checks than this say little either way.
        public var isTooFew: Bool { count < AccuracyReport.minimumForConclusion }
    }

    public static let minimumForConclusion = 5

    public let pairs: [Pair]

    public init(pairs: [Pair]) {
        self.pairs = pairs.sorted { $0.date < $1.date }
    }

    /// Matches each fingerstick with the closest sensor reading within `maxGapMinutes`, and notes
    /// the sensor day and how fast glucose was moving (over the 15 minutes before that reading).
    public init(fingersticks: [FingerstickEntry], readings: [GlucoseReading], maxGapMinutes: Double = 5,
                includeCalibrationPoints: Bool = false) {
        let sorted = readings.sorted { $0.timestamp < $1.timestamp }
        let pairs = fingersticks
            // A stick offered for calibration isn't an independent check, even one refused.
            .filter { includeCalibrationPoints || (!$0.usedForCalibration && $0.offeredForCalibration != true) }
            .compactMap { stick -> Pair? in
                guard let index = Self.closestIndex(to: stick.date, in: sorted) else { return nil }
                let closest = sorted[index]
                guard abs(closest.timestamp.timeIntervalSince(stick.date)) <= maxGapMinutes * 60 else { return nil }
                var window: [GlucoseReading] = []
                var i = index
                while i >= 0, closest.timestamp.timeIntervalSince(sorted[i].timestamp) <= 15 * 60 {
                    if sorted[i].sensorSerial == closest.sensorSerial { window.append(sorted[i]) }
                    i -= 1
                }
                return Pair(date: stick.date, referenceMgdL: stick.mgdL, sensorMgdL: closest.mgdL,
                            libreLinkMgdL: stick.libreLinkMgdL, sensorSerial: closest.sensorSerial,
                            sensorDay: closest.minuteIndex / 1440 + 1, ratePerMinute: Trend.ratePerMinute(window))
            }
        self.init(pairs: pairs)
    }

    // MARK: Overall

    /// Mean absolute relative difference, in percent.
    public var mard: Double? { Self.mard(pairs) }

    public var within15_15: Double? {
        guard !pairs.isEmpty else { return nil }
        return Double(pairs.filter(\.isWithin15_15).count) / Double(pairs.count)
    }

    public var within20_20: Double? {
        guard !pairs.isEmpty else { return nil }
        return Double(pairs.filter(\.isWithin20_20).count) / Double(pairs.count)
    }

    /// Mean of sensor minus meter, in mg/dL: negative when the sensor tends to read low.
    public var biasMgdL: Double? {
        guard !pairs.isEmpty else { return nil }
        return pairs.map(\.difference).reduce(0, +) / Double(pairs.count)
    }

    /// The 95% confidence range of the MARD, from the spread of the checks (t distribution).
    /// Nil below 3 checks, where any range would be meaningless.
    public var mardInterval: ClosedRange<Double>? {
        guard pairs.count >= 3, let mard else { return nil }
        let values = pairs.map { $0.absoluteRelativeDifference * 100 }
        let variance = values.reduce(0) { $0 + ($1 - mard) * ($1 - mard) } / Double(values.count - 1)
        let margin = Self.tQuantile975(degreesOfFreedom: values.count - 1) * variance.squareRoot() / Double(values.count).squareRoot()
        return max(0, mard - margin)...(mard + margin)
    }

    public var dateRange: ClosedRange<Date>? {
        guard let first = pairs.first?.date, let last = pairs.last?.date else { return nil }
        return first...last
    }

    /// How many checks fall in each zone of the consensus error grid.
    public var zoneCounts: [ErrorGridZone: Int] {
        var counts: [ErrorGridZone: Int] = [:]
        for pair in pairs { counts[pair.zone, default: 0] += 1 }
        return counts
    }

    /// LibreLink's MARD on the checks where its value was typed in, next to this app's on the same
    /// checks: the only fair comparison.
    public var libreLinkComparison: (libreLink: Double, app: Double, count: Int)? {
        let both = pairs.filter { $0.libreLinkMgdL != nil }
        guard let app = Self.mard(both) else { return nil }
        let libreLink = both.compactMap { pair in pair.libreLinkMgdL.map { abs($0 - pair.referenceMgdL) / pair.referenceMgdL } }
        return (libreLink.reduce(0, +) / Double(libreLink.count) * 100, app, both.count)
    }

    // MARK: Breakdowns

    public func summary(_ group: Group) -> Summary? {
        let matching = pairs.filter(group.contains)
        return Self.mard(matching).map { Summary(mard: $0, count: matching.count) }
    }

    /// MARD per day of wear for one sensor, keyed by day (1 = first day).
    public func dailySummaries(sensorSerial: String) -> [Int: Summary] {
        let grouped = Dictionary(grouping: pairs.filter { $0.sensorSerial == sensorSerial && $0.sensorDay != nil }) { $0.sensorDay! }
        return grouped.compactMapValues { dayPairs in Self.mard(dayPairs).map { Summary(mard: $0, count: dayPairs.count) } }
    }

    /// One line per check, for a spreadsheet.
    public func csv() -> String {
        let formatter = ISO8601DateFormatter()
        var lines = ["time,meter_mgdl,app_mgdl,librelink_mgdl,difference_mgdl,abs_rel_diff_pct,zone,sensor_day,rate_mgdl_per_min"]
        for pair in pairs {
            lines.append([
                formatter.string(from: pair.date),
                String(format: "%.0f", pair.referenceMgdL),
                String(format: "%.0f", pair.sensorMgdL),
                pair.libreLinkMgdL.map { String(format: "%.0f", $0) } ?? "",
                String(format: "%.0f", pair.difference),
                String(format: "%.1f", pair.absoluteRelativeDifference * 100),
                pair.zone.rawValue,
                pair.sensorDay.map(String.init) ?? "",
                pair.ratePerMinute.map { String(format: "%.2f", $0) } ?? "",
            ].joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: Helpers

    static func mard(_ pairs: [Pair]) -> Double? {
        guard !pairs.isEmpty else { return nil }
        return pairs.map(\.absoluteRelativeDifference).reduce(0, +) / Double(pairs.count) * 100
    }

    /// The reading closest in time to `date` in readings sorted by time.
    static func closestIndex(to date: Date, in sorted: [GlucoseReading]) -> Int? {
        guard !sorted.isEmpty else { return nil }
        var low = 0
        var high = sorted.count
        while low < high {
            let mid = (low + high) / 2
            if sorted[mid].timestamp < date { low = mid + 1 } else { high = mid }
        }
        let candidates = [low - 1, low].filter { sorted.indices.contains($0) }
        return candidates.min { abs(sorted[$0].timestamp.timeIntervalSince(date)) < abs(sorted[$1].timestamp.timeIntervalSince(date)) }
    }

    /// The 97.5th percentile of Student's t distribution, for a two-sided 95% range.
    static func tQuantile975(degreesOfFreedom df: Int) -> Double {
        let table: [Double] = [12.706, 4.303, 3.182, 2.776, 2.571, 2.447, 2.365, 2.306, 2.262, 2.228,
                               2.201, 2.179, 2.160, 2.145, 2.131, 2.120, 2.110, 2.101, 2.093, 2.086,
                               2.080, 2.074, 2.069, 2.064, 2.060, 2.056, 2.052, 2.048, 2.045, 2.042]
        if df >= 1, df <= table.count { return table[df - 1] }
        return 1.96 + 2.5 / Double(max(df, 1))
    }
}

/// Zones of the consensus (Parkes) error grid: A = no effect on treatment, B = little or no
/// effect, C = likely to affect it, D = could be dangerous, E = would be dangerous.
public enum ErrorGridZone: String, CaseIterable, Codable, Comparable, Sendable {
    case a = "A", b = "B", c = "C", d = "D", e = "E"

    public static func < (lhs: ErrorGridZone, rhs: ErrorGridZone) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}

/// The consensus error grid for type 1 diabetes (Parkes et al. 2000), with the zone boundaries
/// published by Pfützner et al. (J Diabetes Sci Technol 2013). Meter on x, sensor on y, mg/dL.
public enum ParkesErrorGrid {
    public struct Vertex: Hashable, Sendable {
        public let x: Double
        public let y: Double
        init(_ x: Double, _ y: Double) { self.x = x; self.y = y }
    }

    /// A boundary between two zones: the upper one runs above the diagonal, the lower one below.
    public struct Boundary: Hashable, Sendable {
        public let inner: ErrorGridZone
        public let upper: [Vertex]
        public let lower: [Vertex]?
    }

    /// From the innermost boundary (around A) outwards.
    public static let boundaries: [Boundary] = [
        Boundary(inner: .a,
                 upper: [Vertex(0, 50), Vertex(30, 50), Vertex(140, 170), Vertex(280, 380), Vertex(430, 550)],
                 lower: [Vertex(50, 0), Vertex(50, 30), Vertex(170, 145), Vertex(385, 300), Vertex(550, 450)]),
        Boundary(inner: .b,
                 upper: [Vertex(0, 60), Vertex(30, 60), Vertex(50, 80), Vertex(70, 110), Vertex(260, 550)],
                 lower: [Vertex(120, 0), Vertex(120, 30), Vertex(260, 130), Vertex(550, 250)]),
        Boundary(inner: .c,
                 upper: [Vertex(0, 100), Vertex(25, 100), Vertex(50, 125), Vertex(80, 215), Vertex(125, 550)],
                 lower: [Vertex(250, 0), Vertex(250, 40), Vertex(550, 150)]),
        Boundary(inner: .d,
                 upper: [Vertex(0, 150), Vertex(35, 155), Vertex(50, 550)],
                 lower: nil),
    ]

    public static func zone(referenceMgdL x: Double, sensorMgdL y: Double) -> ErrorGridZone {
        // Outermost first: a point outside a boundary belongs to the zone beyond it.
        for boundary in boundaries.reversed() {
            let above = value(of: boundary.upper, at: x).map { y > $0 } ?? false
            let below = boundary.lower.flatMap { value(of: $0, at: x) }.map { y < $0 } ?? false
            if above || below { return ErrorGridZone.allCases[ErrorGridZone.allCases.firstIndex(of: boundary.inner)! + 1] }
        }
        return .a
    }

    /// The boundary's y at `x`, continuing its last segment beyond the last vertex. Nil left of
    /// its first vertex (a lower boundary starts on the x axis, so nothing there is below it).
    /// On a vertical step the top of the step counts.
    public static func value(of line: [Vertex], at x: Double) -> Double? {
        guard let first = line.first, x >= first.x, line.count >= 2 else { return nil }
        for i in 1..<line.count {
            let a = line[i - 1]
            let b = line[i]
            if x <= b.x {
                if b.x == a.x { return b.y }
                return a.y + (x - a.x) / (b.x - a.x) * (b.y - a.y)
            }
        }
        let a = line[line.count - 2]
        let b = line[line.count - 1]
        return b.y + (x - b.x) / (b.x - a.x) * (b.y - a.y)
    }
}
