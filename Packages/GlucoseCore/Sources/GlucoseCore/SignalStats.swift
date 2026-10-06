import Foundation

/// How well the Bluetooth link works: packets, corrupt packets, reconnects, signal strength and
/// unusable values, counted per hour, plus each time the link was lost and why. Kept for a
/// sensor's life (16 days), so the Sensor screen can explain gaps.
public struct SignalStats: Codable, Hashable, Sendable {
    public struct Hour: Codable, Hashable, Sendable {
        public var start: Date
        public var packets = 0
        public var corruptPackets = 0
        public var reconnects = 0
        /// Minutes where the sensor's value couldn't be used (an error flag or an impossible value).
        public var unusableValues = 0
        public var rssiSum = 0.0
        public var rssiCount = 0

        public init(start: Date) { self.start = start }
    }

    public enum OutageReason: String, Codable, Sendable {
        /// Bluetooth was turned off on the phone.
        case bluetoothOff
        /// The link dropped: the phone was out of range, or the body blocked the signal.
        case linkLost
        /// The app stopped the connection in the background (Run in background is off).
        case appPaused
    }

    /// A time the link was down. `end` is nil while it still is.
    public struct Outage: Codable, Hashable, Sendable {
        public var start: Date
        public var end: Date?
        public var reason: OutageReason

        public func interval(now: Date) -> DateInterval {
            DateInterval(start: start, end: max(start, end ?? now))
        }
    }

    public struct Summary: Hashable, Sendable {
        public var packets = 0
        public var corruptPackets = 0
        public var reconnects = 0
        public var unusableValues = 0
        public var averageRSSI: Double?
        /// Minutes the counting covers: a packet a minute is expected.
        public var minutes = 0.0

        /// Packets received as a share of one a minute.
        public var packetShare: Double? { minutes >= 1 ? min(1, Double(packets) / minutes.rounded()) : nil }
    }

    public enum SignalQuality: String, Sendable {
        case good, fair, weak

        public init(rssi: Double) {
            if rssi >= -75 {
                self = .good
            } else if rssi >= -88 {
                self = .fair
            } else {
                self = .weak
            }
        }
    }

    public enum NoiseLevel: String, Sendable {
        case low, medium, high
    }

    public static let keepDays = 16.0
    static let maxOutages = 300

    public private(set) var hours: [Hour] = []
    public private(set) var outages: [Outage] = []
    /// When counting started (first install of this version, or after Delete all data).
    public private(set) var countingSince: Date?

    public init() {}

    // MARK: Recording

    public mutating func recordPacket(at date: Date, unusable: Bool) {
        update(at: date) {
            $0.packets += 1
            if unusable { $0.unusableValues += 1 }
        }
        linkRestored(at: date)
    }

    public mutating func recordCorruptPacket(at date: Date) {
        update(at: date) { $0.corruptPackets += 1 }
    }

    public mutating func recordReconnect(at date: Date) {
        update(at: date) { $0.reconnects += 1 }
    }

    public mutating func recordRSSI(_ rssi: Double, at date: Date) {
        // CoreBluetooth reports 127 when the value isn't available.
        guard rssi < 0, rssi > -130 else { return }
        update(at: date) {
            $0.rssiSum += rssi
            $0.rssiCount += 1
        }
    }

    /// The link went down. A later reason replaces an earlier one for the same outage only when
    /// it says more (Bluetooth off, or the app pausing, explains a lost link).
    public mutating func linkLost(at date: Date, reason: OutageReason) {
        if countingSince == nil { countingSince = date }
        if let index = outages.indices.last, outages[index].end == nil {
            // The first specific reason stays: Bluetooth off and then the app closed was a
            // Bluetooth outage from the start.
            if outages[index].reason == .linkLost { outages[index].reason = reason }
            return
        }
        outages.append(Outage(start: date, end: nil, reason: reason))
        if outages.count > Self.maxOutages { outages.removeFirst(outages.count - Self.maxOutages) }
    }

    /// Closes the open outage without data having come back, e.g. when the sensor ends.
    public mutating func endOpenOutage(at date: Date) {
        guard let index = outages.indices.last, outages[index].end == nil else { return }
        outages[index].end = max(outages[index].start, date)
    }

    /// Data flows again: closes the open outage. One shorter than 2 minutes is a normal
    /// reconnect, not worth listing.
    public mutating func linkRestored(at date: Date) {
        guard let index = outages.indices.last, outages[index].end == nil else { return }
        if date.timeIntervalSince(outages[index].start) < 120 {
            outages.remove(at: index)
        } else {
            outages[index].end = date
        }
    }

    public mutating func prune(now: Date) {
        let cutoff = now.addingTimeInterval(-Self.keepDays * 86_400)
        hours.removeAll { $0.start < cutoff }
        outages.removeAll { ($0.end ?? now) < cutoff }
    }

    private mutating func update(at date: Date, _ change: (inout Hour) -> Void) {
        if countingSince == nil { countingSince = date }
        let start = Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 3600).rounded(.down) * 3600)
        if let index = hours.lastIndex(where: { $0.start == start }) {
            change(&hours[index])
        } else {
            var hour = Hour(start: start)
            change(&hour)
            hours.append(hour)
            hours.sort { $0.start < $1.start }
        }
    }

    // MARK: Reading

    /// Totals for the hours that start inside `interval`. Minutes count from when counting began.
    public func summary(in interval: DateInterval) -> Summary {
        var summary = Summary()
        var rssiSum = 0.0
        var rssiCount = 0
        for hour in hours where hour.start >= interval.start.addingTimeInterval(-3599) && hour.start < interval.end {
            summary.packets += hour.packets
            summary.corruptPackets += hour.corruptPackets
            summary.reconnects += hour.reconnects
            summary.unusableValues += hour.unusableValues
            rssiSum += hour.rssiSum
            rssiCount += hour.rssiCount
        }
        summary.averageRSSI = rssiCount > 0 ? rssiSum / Double(rssiCount) : nil
        // Whole hours are counted, so the expected minutes start where the first counted hour does.
        let firstHour = Date(timeIntervalSince1970: (interval.start.timeIntervalSince1970 / 3600).rounded(.down) * 3600)
        let start = max(firstHour, countingSince ?? interval.end)
        summary.minutes = max(0, interval.end.timeIntervalSince(start) / 60)
        return summary
    }

    /// Outages of at least `minimumMinutes` overlapping `interval`, newest first.
    public func outages(in interval: DateInterval, now: Date, minimumMinutes: Double = 5) -> [Outage] {
        outages
            .filter { outage in
                let span = outage.interval(now: now)
                return span.duration >= minimumMinutes * 60 && span.end > interval.start && span.start < interval.end
            }
            .sorted { $0.start > $1.start }
    }

    // MARK: Gaps and noise

    /// Stretches without readings longer than `minimumMinutes`, between `interval`'s start and
    /// end, newest first. The edges count too: no reading since the start is a gap.
    public static func dataGaps(in readings: [GlucoseReading], interval: DateInterval,
                                minimumMinutes: Double = 20) -> [DateInterval] {
        let times = readings.map(\.timestamp).filter { interval.contains($0) }.sorted()
        var gaps: [DateInterval] = []
        var previous = interval.start
        for time in times + [interval.end] {
            if time.timeIntervalSince(previous) > minimumMinutes * 60 {
                gaps.append(DateInterval(start: previous, end: time))
            }
            previous = max(previous, time)
        }
        return gaps.reversed()
    }

    /// Whether readings cover `interval`: at least 80% of its 15-minute slots hold a reading.
    /// A gap the NFC history filled (one value per 15 minutes) counts as covered.
    public static func isCovered(_ interval: DateInterval, by readings: [GlucoseReading]) -> Bool {
        let slots = max(1, Int((interval.duration / 900).rounded(.up)))
        let filled = Set(readings.filter { interval.contains($0.timestamp) }
            .map { Int($0.timestamp.timeIntervalSince(interval.start) / 900) })
        return Double(filled.count) / Double(slots) >= 0.8
    }

    /// Minute-to-minute jitter: the median distance of each 1-minute reading from the midpoint of
    /// its neighbours, in mg/dL. Real glucose changes smoothly, so this is mostly signal noise.
    public static func noise(in readings: [GlucoseReading]) -> (mgdL: Double, level: NoiseLevel)? {
        let sorted = readings.sorted { $0.timestamp < $1.timestamp }
        var deviations: [Double] = []
        if sorted.count >= 3 {
            for i in 1..<(sorted.count - 1) {
                let a = sorted[i - 1], b = sorted[i], c = sorted[i + 1]
                guard a.sensorSerial == b.sensorSerial, b.sensorSerial == c.sensorSerial,
                      b.minuteIndex - a.minuteIndex == 1, c.minuteIndex - b.minuteIndex == 1 else { continue }
                deviations.append(abs(b.mgdL - (a.mgdL + c.mgdL) / 2))
            }
        }
        guard deviations.count >= 30 else { return nil }
        let median = deviations.sorted()[deviations.count / 2]
        let level: NoiseLevel = median < 1.5 ? .low : median < 3 ? .medium : .high
        return (median, level)
    }
}

/// One day of a sensor's wear, for the Sensor screen's day strip.
public struct SensorWearDay: Hashable, Sendable, Identifiable {
    public let day: Int
    /// Share of the day's 15-minute slots with a reading; nil for days still ahead.
    public let coverage: Double?
    public let calibrations: Int
    public let accuracy: AccuracyReport.Summary?
    public let isToday: Bool

    public var id: Int { day }
}

public enum SensorWear {
    /// Coverage, calibrations and accuracy per day of wear, day 1 first. The first hour of day 1
    /// is warm-up and doesn't count. `firstMinute` is the sensor minute at `activatedAt` (0 for a
    /// real sensor; the demo's endless sensor starts its "wear" later).
    public static func days(readings: [GlucoseReading], sensorSerial: String, activatedAt: Date, lifetimeDays: Int,
                            fingersticks: [FingerstickEntry], accuracy: AccuracyReport, now: Date,
                            firstMinute: Int = 0) -> [SensorWearDay] {
        var slotsByDay: [Int: Set<Int>] = [:]
        for reading in readings where reading.sensorSerial == sensorSerial && reading.minuteIndex >= firstMinute {
            let minute = reading.minuteIndex - firstMinute
            slotsByDay[minute / 1440, default: []].insert((minute % 1440) / 15)
        }
        func dayIndex(_ date: Date) -> Int { Int((date.timeIntervalSince(activatedAt) / 86_400).rounded(.down)) }
        let calibrationDays = fingersticks
            .filter { $0.usedForCalibration && ($0.sensorSerial == nil || $0.sensorSerial == sensorSerial) && $0.date >= activatedAt }
            .map { dayIndex($0.date) }
        let checksByDay = Dictionary(grouping: accuracy.pairs.filter { $0.sensorSerial == sensorSerial && $0.date >= activatedAt },
                                     by: { dayIndex($0.date) })
        let daily = checksByDay.compactMapValues { pairs in
            AccuracyReport.mard(pairs).map { AccuracyReport.Summary(mard: $0, count: pairs.count) }
        }
        let elapsedMinutes = now.timeIntervalSince(activatedAt) / 60

        return (0..<max(1, lifetimeDays)).map { index in
            let dayStart = Double(index * 1440)
            let firstSlot = index == 0 ? 4 : 0 // warm-up: the first 60 minutes
            let slotsSoFar = Int(((min(elapsedMinutes, dayStart + 1440) - dayStart) / 15).rounded(.down)) - firstSlot
            let filled = (slotsByDay[index] ?? []).filter { $0 >= firstSlot }.count
            let coverage: Double? = elapsedMinutes <= dayStart ? nil
                : slotsSoFar <= 0 ? nil
                : min(1, Double(filled) / Double(slotsSoFar))
            return SensorWearDay(day: index + 1, coverage: coverage,
                                 calibrations: calibrationDays.filter { $0 == index }.count,
                                 accuracy: daily[index],
                                 isToday: elapsedMinutes >= dayStart && elapsedMinutes < dayStart + 1440)
        }
    }
}
