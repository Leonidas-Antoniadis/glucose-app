import Foundation

/// Sensor accuracy against fingersticks, each compared with what the app showed before it.
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
        /// The fingerstick was then used to calibrate (`sensorMgdL` is still the value from before).
        public let usedForCalibration: Bool

        public init(date: Date, referenceMgdL: Double, sensorMgdL: Double, libreLinkMgdL: Double? = nil,
                    sensorSerial: String? = nil, sensorDay: Int? = nil, ratePerMinute: Double? = nil,
                    usedForCalibration: Bool = false) {
            self.date = date
            self.referenceMgdL = referenceMgdL
            self.sensorMgdL = sensorMgdL
            self.libreLinkMgdL = libreLinkMgdL
            self.sensorSerial = sensorSerial
            self.sensorDay = sensorDay
            self.ratePerMinute = ratePerMinute
            self.usedForCalibration = usedForCalibration
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
    /// Checks with no sensor reading in the minutes before them (a Bluetooth gap, say), left out.
    public let unpairedCount: Int

    public init(pairs: [Pair], unpairedCount: Int = 0) {
        self.pairs = pairs.sorted { $0.date < $1.date }
        self.unpairedCount = unpairedCount
    }

    /// Matches each fingerstick with the newest reading of its sensor at or before it, within
    /// `maxGapMinutes`: never a later one, which would know where glucose went. The app's value
    /// is the one saved with the check when there is one (later calibrations rewrite readings).
    /// Also notes the sensor day and how fast glucose was moving (the 15 minutes before).
    public init(fingersticks: [FingerstickEntry], readings: [GlucoseReading], maxGapMinutes: Double = 5,
                includeCalibrationPoints: Bool = false) {
        let sorted = readings.sorted { $0.timestamp < $1.timestamp }
        let checks = fingersticks.filter { includeCalibrationPoints || Self.isScored($0) }
        let pairs = checks.compactMap { stick -> Pair? in
            guard let index = Self.latestIndex(atOrBefore: stick.date, in: sorted, serial: stick.sensorSerial,
                                               maxGap: maxGapMinutes * 60) else { return nil }
            let reading = sorted[index]
            var window: [GlucoseReading] = []
            var i = index
            while i >= 0, reading.timestamp.timeIntervalSince(sorted[i].timestamp) <= 15 * 60 {
                if sorted[i].sensorSerial == reading.sensorSerial { window.append(sorted[i]) }
                i -= 1
            }
            return Pair(date: stick.date, referenceMgdL: stick.mgdL, sensorMgdL: stick.appMgdL ?? reading.mgdL,
                        libreLinkMgdL: stick.libreLinkMgdL, sensorSerial: reading.sensorSerial,
                        sensorDay: reading.minuteIndex / 1440 + 1, ratePerMinute: Trend.ratePerMinute(window),
                        usedForCalibration: stick.usedForCalibration)
        }
        self.init(pairs: pairs, unpairedCount: checks.count - pairs.count)
    }

    /// Whether a fingerstick counts as an accuracy check. One used to calibrate counts, against the
    /// value shown before it was used (saved with it): leaving calibrations out would leave out
    /// exactly the big misses, when you calibrate because the sensor is far off. Older calibrations
    /// without that saved value don't count, since their readings were refitted to them. A stick
    /// that was offered but not used (far off until a second one agrees, say, which may be a meter
    /// error) doesn't count either; the stick that confirms it does.
    public static func isScored(_ stick: FingerstickEntry) -> Bool {
        if stick.usedForCalibration { return stick.appMgdL != nil }
        return stick.offeredForCalibration != true
    }

    // MARK: Overall

    /// Mean absolute relative difference, in percent.
    public var mard: Double? { Self.mard(pairs) }

    public var within15_15: Double? {
        guard !pairs.isEmpty else { return nil }
        return Double(pairs.filter(\.isWithin15_15).count) / Double(pairs.count)
    }

    /// The checks outside the 15 mg/dL / 15 % band, newest first: the times the sensor was off.
    public var misses: [Pair] {
        pairs.filter { !$0.isWithin15_15 }.sorted { $0.date > $1.date }
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

    /// The newest reading at or before `date`, no more than `maxGap` seconds earlier, from
    /// `serial` when one is given, in readings sorted by time.
    static func latestIndex(atOrBefore date: Date, in sorted: [GlucoseReading], serial: String?,
                            maxGap: TimeInterval) -> Int? {
        var low = 0
        var high = sorted.count
        while low < high {
            let mid = (low + high) / 2
            if sorted[mid].timestamp <= date { low = mid + 1 } else { high = mid }
        }
        var index = low - 1
        while index >= 0, date.timeIntervalSince(sorted[index].timestamp) <= maxGap {
            if serial == nil || sorted[index].sensorSerial == serial { return index }
            index -= 1
        }
        return nil
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
