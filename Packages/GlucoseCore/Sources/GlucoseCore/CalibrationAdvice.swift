import Foundation

/// The paired sensor, as the calibration advice needs it.
public struct CalibrationSensor: Sendable {
    public var serial: String
    public var activatedAt: Date
    public var warmUpEndsAt: Date
    public var lifetimeDays: Int
    public var calibration: Calibration
    public var calibrationPoints: [CalibrationPoint]
    /// A fingerstick far from the sensor, waiting for a second one to confirm it.
    public var unconfirmedPoint: CalibrationPoint?

    public init(serial: String, activatedAt: Date, warmUpEndsAt: Date, lifetimeDays: Int, calibration: Calibration,
                calibrationPoints: [CalibrationPoint] = [], unconfirmedPoint: CalibrationPoint? = nil) {
        self.serial = serial
        self.activatedAt = activatedAt
        self.warmUpEndsAt = warmUpEndsAt
        self.lifetimeDays = lifetimeDays
        self.calibration = calibration
        self.calibrationPoints = calibrationPoints
        self.unconfirmedPoint = unconfirmedPoint
    }
}

/// What the calibration advice looks at.
public struct CalibrationAdviceInput: Sendable {
    /// When the fingerstick was taken.
    public var date: Date
    /// The meter's value. Nil before it's typed: then only the moment is judged.
    public var meterMgdL: Double?
    public var sensor: CalibrationSensor?
    /// Readings around `date` (the 45 minutes before are enough). Other sensors' are ignored.
    public var readings: [GlucoseReading] = []
    /// The newest reading, to show what calibrating would change.
    public var latest: GlucoseReading?
    public var logbook: [LogEntry] = []
    /// Earlier fingersticks: what the checks since the last calibration showed.
    public var fingersticks: [FingerstickEntry] = []
    /// What the app showed for that moment when it's already known (a fingerstick being edited).
    /// Otherwise it's the reading the calibration pairs with.
    public var shownMgdL: Double?
    /// The demo: its readings have no raw signal, and nothing gets calibrated.
    public var isDemo = false

    public init(date: Date, meterMgdL: Double? = nil, sensor: CalibrationSensor? = nil) {
        self.date = date
        self.meterMgdL = meterMgdL
        self.sensor = sensor
    }
}

/// Whether to calibrate with a fingerstick, and why.
public struct CalibrationAdvice: Hashable, Sendable {
    public enum Verdict: String, Sendable {
        /// A good moment, and calibrating helps.
        case calibrate
        /// Close to the meter: keep the value as an accuracy check.
        case notNeeded
        /// A little off (15–20 %), which can be meter error: calibrate if the next check is off the same way.
        case checkAgain
        /// Glucose is moving or about to, or the sensor is too new: save without calibrating.
        case wait
        /// Far from the sensor: more often a test error, so test again.
        case testAgain
        /// The calibration couldn't use it (no sensor, warm-up, no sensor value at that time).
        case cannot
    }

    /// One thing the advice looked at.
    public struct Factor: Identifiable, Hashable, Sendable {
        public enum Status: Int, Comparable, Sendable {
            /// A reason not to calibrate now.
            case problem
            /// Makes a calibration less reliable. Two together are a reason to wait.
            case warning
            case ok
            /// A fact for the decision, neither good nor bad.
            case info

            public static func < (lhs: Status, rhs: Status) -> Bool { lhs.rawValue < rhs.rawValue }
        }

        public let id: String
        public let status: Status
        public let title: String
        public let detail: String
        /// The same as part of a sentence ("fast insulin is still working"), for the summary.
        let reason: String

        init(id: String, status: Status, title: String, detail: String = "", reason: String = "") {
            self.id = id
            self.status = status
            self.title = title
            self.detail = detail
            self.reason = reason
        }
    }

    public let verdict: Verdict
    public let title: String
    public let summary: String
    /// The comparison with the sensor first, then the conditions (problems first), then the rest.
    public let factors: [Factor]

    /// Whether "Use to calibrate" should be on. Nil after a far-off value: whether to offer it
    /// depends on what it's for (only an offered one waits for a second fingerstick to agree).
    public var recommendsCalibrating: Bool? {
        switch verdict {
        case .calibrate: return true
        case .notNeeded, .checkAgain, .wait, .cannot: return false
        case .testAgain: return nil
        }
    }
}

/// Advice for a fingerstick, following the calibration guide: no calibration in a sensor's first
/// 12–24 hours; from day 2 two at different levels; after that only when a check is far off. Always
/// with glucose steady: no fast insulin or food in the 2 hours before and a flat arrow, since the
/// sensor trails blood by 5–10 minutes and while glucose moves part of any difference is that delay.
public enum CalibrationAdvisor {
    public typealias Factor = CalibrationAdvice.Factor

    /// Below this rate, in mg/dL per minute, the arrow is flat; above `fastRate` glucose changes fast.
    public static let steadyRate = 1.0
    public static let fastRate = 2.0
    /// Moving at least this fast 15 to 30 minutes before, and steady now: glucose has just turned.
    static let turnRate = 1.5
    /// At most how far the sensor trails blood, in minutes: while glucose moves, a meter can read
    /// up to the rate times this away from the sensor.
    public static let lagMinutes = 10.0
    /// From this much fast insulin still working, even 2 hours after it, glucose is about to move.
    public static let waitInsulinUnits = 1.0
    /// A one-minute step this big isn't glucose: pressure on the sensor or a knock.
    static let jumpMgdL = 10.0
    /// Younger than this a sensor isn't calibrated at all; until a day old it's a warning.
    public static let youngSensorHours = 12.0

    /// What the accuracy screen counts as on target: within 15 mg/dL below 100 mg/dL, 15 % from there up.
    public static func isClose(meterMgdL: Double, sensorMgdL: Double) -> Bool {
        AccuracyReport.Pair(date: .distantPast, referenceMgdL: meterMgdL, sensorMgdL: sensorMgdL).isWithin15_15
    }

    /// More than 20 mg/dL below 100 mg/dL, or 20 % from there up: red under Accuracy → Times it was off.
    public static func isFarOff(meterMgdL: Double, sensorMgdL: Double) -> Bool {
        !AccuracyReport.Pair(date: .distantPast, referenceMgdL: meterMgdL, sensorMgdL: sensorMgdL).isWithin20_20
    }

    public static func advise(_ input: CalibrationAdviceInput, unit: GlucoseUnit,
                              time: (Date) -> String) -> CalibrationAdvice {
        let date = input.date
        guard let sensor = input.sensor else {
            return cannot("No sensor is paired, so there's nothing to calibrate.")
        }
        if !input.isDemo {
            if date < sensor.warmUpEndsAt {
                return cannot("The sensor is warming up until \(time(sensor.warmUpEndsAt)). Calibrate after that.")
            }
            if let newest = sensor.calibrationPoints.map(\.date).max(),
               newest.timeIntervalSince(date) > Calibration.maxAgeHours * 3600 {
                return cannot("That time is more than 4 days before the newest calibration.")
            }
        }
        let readings = input.readings.filter { $0.sensorSerial == sensor.serial }.sorted { $0.timestamp < $1.timestamp }
        // The reading the calibration would pair with: the closest within 3 minutes, with a raw value.
        let usable = readings.filter { abs($0.timestamp.timeIntervalSince(date)) <= 3 * 60 && (input.isDemo || $0.raw != nil) }
        guard let atStick = usable.min(by: { abs($0.timestamp.timeIntervalSince(date)) < abs($1.timestamp.timeIntervalSince(date)) }) else {
            return cannot("There's no sensor value within 3 minutes of that time.")
        }

        // Conditions: is glucose steady, and will it stay so?
        let context = LogContext.at(date, in: input.logbook)
        let rate = Trend.ratePerMinute(readings.filter { $0.timestamp <= date.addingTimeInterval(60) })
        let earlierRate = Trend.ratePerMinute(readings.filter {
            $0.timestamp > date.addingTimeInterval(-30 * 60) && $0.timestamp <= date.addingTimeInterval(-15 * 60)
        })
        let insulinSettles = context.insulinOnBoard >= InsulinOnBoard.activeUnits
            ? InsulinOnBoard.time(whenBelow: InsulinOnBoard.activeUnits, after: date, in: input.logbook) : nil
        var conditions: [Factor] = []
        if let low = lowFactor(meter: input.meterMgdL, sensorMgdL: atStick.mgdL, unit: unit) { conditions.append(low) }
        conditions.append(trendFactor(rate: rate, earlier: earlierRate, unit: unit))
        conditions.append(insulinFactor(context, settlesAt: insulinSettles, time: time))
        conditions.append(foodFactor(context))
        if let exercise = exerciseFactor(context) { conditions.append(exercise) }
        // Simulated readings wobble on purpose; that isn't a disturbed signal.
        if !input.isDemo, let signal = signalFactor(readings, date: date, unit: unit) { conditions.append(signal) }
        conditions.append(dayFactor(sensor, date: date))
        conditions = conditions.enumerated()
            .sorted { $0.element.status != $1.element.status ? $0.element.status < $1.element.status : $0.offset < $1.offset }
            .map(\.element)

        let problems = conditions.filter { $0.status == .problem }
        let warnings = conditions.filter { $0.status == .warning }
        let unsettled = !problems.isEmpty || warnings.count >= 2
        let isLow = problems.contains { $0.id == "low" }
        let isYoung = problems.contains { $0.id == "day" }
        let because = sentence((problems.isEmpty ? warnings : problems).prefix(2).map(\.reason))
        // When everything logged has stopped moving glucose.
        var settleTimes = [insulinSettles].compactMap { $0 }
        if let dose = context.workingDoses.last, (context.minutesSinceInsulin ?? .infinity) < LogContext.insulinMinutes {
            settleTimes.append(dose.date.addingTimeInterval(LogContext.insulinMinutes * 60))
        }
        settleTimes += context.foods.compactMap { food -> Date? in
            let effect = foodEffect(food, at: date)
            return effect.status == .ok ? nil : effect.until
        }
        if let since = context.minutesSinceExercise {
            settleTimes.append(date.addingTimeInterval((LogContext.afterExerciseMinutes - since) * 60))
        }
        let around = settleTimes.max().flatMap { $0 > date ? ", around \(time($0))" : nil } ?? ""
        let young = "The sensor is only \(Int(date.timeIntervalSince(sensor.activatedAt) / 3600)) h old: don't calibrate in its first 12–24 hours."

        var info = input.isDemo ? [] : [calibrationFactor(sensor.calibration, date: date)]
        if let lastDay = lastDayFactor(sensor, date: date) { info.append(lastDay) }
        let demo = input.isDemo ? [Factor(id: "demo", status: .info, title: "Demo", detail: "Calibration only applies to a real sensor.")] : []

        guard let meter = input.meterMgdL else {
            // Before the value is typed: only whether this is a good moment.
            let factors = conditions + info + demo
            if isLow {
                return CalibrationAdvice(verdict: .wait, title: "Not a good time to calibrate",
                                         summary: "Check with your meter and treat a low first. Calibrate later, when glucose is steady.",
                                         factors: factors)
            }
            if isYoung {
                return CalibrationAdvice(verdict: .wait, title: "Not a good time to calibrate",
                                         summary: young + " Take checks with Use to calibrate off until then.", factors: factors)
            }
            if unsettled {
                return CalibrationAdvice(verdict: .wait, title: "Not a good time to calibrate",
                                         summary: "\(because). Calibrate when glucose is steady\(around).", factors: factors)
            }
            return CalibrationAdvice(verdict: .calibrate, title: "Good time to calibrate",
                                     summary: warnings.first.map { "A good enough moment, though \($0.reason)." }
                                         ?? "Glucose is steady, with no fast insulin or food in the last 2 hours.",
                                     factors: factors)
        }

        // How far the sensor is from the meter, in the bands of Accuracy → Times it was off.
        let shown = input.shownMgdL ?? atStick.mgdL
        // What the calibration itself compares with: the raw signal through the current calibration.
        let expected = atStick.raw.map { sensor.calibration.mgdL(fromRaw: $0) } ?? shown
        let difference = meter - shown
        let close = isClose(meterMgdL: meter, sensorMgdL: shown)
        let farOff = isFarOff(meterMgdL: meter, sensorMgdL: shown)
        let size = unit.format(mgdL: abs(difference), includeSymbol: true)
        let percent = Int((abs(difference) / meter * 100).rounded())
        let direction = difference > 0 ? "low" : "high"
        let closeBand = meter < 100 ? unit.format(mgdL: 15, includeSymbol: true) : "15 %"
        let farBand = meter < 100 ? unit.format(mgdL: 20, includeSymbol: true) : "20 %"
        let movingRate = rate.flatMap { abs($0) >= steadyRate ? $0 : nil }
        // While glucose moves, blood is ahead of the sensor: on a rise a meter reads higher.
        let delayExplains = movingRate.map {
            difference * $0 > 0 && abs(difference) <= abs($0) * lagMinutes + max(15, 0.15 * meter)
        } ?? false
        let pending = input.isDemo ? nil : sensor.unconfirmedPoint
        let confirms = pending.flatMap { point in
            atStick.raw.map { sensor.calibration.confirms(point, referenceMgdL: meter, raw: $0, date: date) }
        } ?? false
        let isOutlier = !confirms && Calibration.isOutlier(referenceMgdL: meter, sensorMgdL: expected)

        // The calibration's levels so far: with all of them at about one level, no slope can be fitted.
        let levels = sensor.calibrationPoints
            .filter { date.timeIntervalSince($0.date) <= Calibration.maxAgeHours * 3600 }
            .map(\.referenceMgdL)
        let hasSlope = (levels.max() ?? 0) - (levels.min() ?? 0) >= Calibration.minimumSpreadMgdL
        let newLevel = !levels.isEmpty && !hasSlope && levels.allSatisfy { abs($0 - meter) >= Calibration.minimumSpreadMgdL }
        let firstCalibration = !sensor.calibration.isCalibrated
        let checks = recentChecks(input.fingersticks, sensor: sensor, date: date)
        let previousOffSameWay = checks.first.map { check -> Bool in
            let shownThen = check.appMgdL ?? check.mgdL
            return !isClose(meterMgdL: check.mgdL, sensorMgdL: shownThen) && (check.mgdL - shownThen) * difference > 0
        } ?? false

        let comparisonDetail: String
        if close {
            comparisonDetail = abs(difference) < 1 ? "The same value." : "Reads \(size) \(direction): close, within \(closeBand)."
        } else if farOff {
            comparisonDetail = "Reads \(size) \(direction) (\(percent) %): far off, more than \(farBand)."
        } else {
            comparisonDetail = "Reads \(size) \(direction) (\(percent) %): a little off, between \(closeBand) and \(farBand)."
        }
        var factors = [Factor(id: "difference", status: .info,
                              title: "Sensor \(unit.formatReading(mgdL: shown)), meter \(unit.format(mgdL: meter, includeSymbol: true))",
                              detail: comparisonDetail)]
        factors += conditions + info
        if let checksSummary = checksFactor(checks, sensor: sensor, difference: difference, meter: meter, unit: unit) {
            factors.append(checksSummary)
        }
        if !isYoung, let level = levelFactor(levels, hasSlope: hasSlope, newLevel: newLevel, unit: unit) {
            factors.append(level)
        }
        func advice(_ verdict: CalibrationAdvice.Verdict, _ title: String, _ summary: String,
                    _ extra: [Factor] = []) -> CalibrationAdvice {
            CalibrationAdvice(verdict: verdict, title: title, summary: summary, factors: factors + extra + demo)
        }

        if isLow {
            return advice(.wait, "Treat the low first",
                          "Glucose moves fast after treating a low. Save this without calibrating, and calibrate later when glucose is steady.")
        }
        if isYoung {
            return advice(.wait, "Don't calibrate yet", young + " Save this as a check: it still measures accuracy.")
        }
        if isOutlier {
            let far = "\(unit.format(mgdL: meter, includeSymbol: true)) is far from the sensor's \(unit.formatReading(mgdL: shown))."
            if unsettled {
                return advice(.wait, "Don't calibrate now", "\(far) \(because), so test again when glucose is steady\(around).")
            }
            var summary = far + (sensor.calibration.isCalibrated
                ? " That's more often a test error, such as sugar on the finger, than the sensor. Wash and dry your hands and test again."
                : " Uncalibrated values can be that far off, so test again to be sure.")
            summary += " With Use to calibrate on, a second fingerstick within 30 minutes that agrees is used."
            if shown < 70, difference > 0 {
                summary += " Lying on the sensor can make it read low for a while."
            }
            return advice(.testAgain, "Test again first", summary)
        }
        // The first two calibrations are worth it even when the sensor is close: they set its level and slope.
        let buildsCalibration = firstCalibration || newLevel
        if close, !buildsCalibration {
            return advice(.notNeeded, "No need to calibrate",
                          (abs(difference) < 1 ? "The sensor shows the same as your meter."
                              : "The sensor is \(size) from your meter, within \(closeBand).")
                          + " Save it as an accuracy check.")
        }
        if unsettled {
            if delayExplains, let moving = movingRate {
                return advice(.wait, "Don't calibrate now",
                              "Most of the \(size) difference is the sensor's 5–10 minute delay while glucose \(moving > 0 ? "rises" : "falls"). Save it without calibrating, and test again when the arrow is flat.")
            }
            return advice(.wait, "Don't calibrate now",
                          "\(because). Save it without calibrating, and calibrate when glucose is steady\(around).")
        }
        let summary: String
        if confirms, let pending {
            summary = "It agrees with your fingerstick at \(time(pending.date)): the sensor really reads \(size) \(direction)."
        } else if firstCalibration {
            summary = "Values are rough estimates until the first calibration."
        } else if newLevel {
            summary = "Your calibrations so far were near \(levelText(levels, unit: unit)): one at a second level lets the app fit the slope."
        } else if farOff {
            summary = "The sensor reads \(size) \(direction) (\(percent) %), more than \(farBand) off."
        } else if previousOffSameWay {
            summary = "The sensor reads \(size) \(direction) (\(percent) %), and your last check was off the same way."
        } else {
            return advice(.checkAgain, "Check again before calibrating",
                          "The sensor reads \(size) \(direction) (\(percent) %). That can be meter error: save it as a check, and calibrate if the next check is off the same way.")
        }
        let moment = warnings.first.map { " Now is good enough, though \($0.reason)." } ?? " Glucose is steady, so now is a good moment."
        var extra: [Factor] = []
        if !input.isDemo, let raw = atStick.raw,
           let preview = previewFactor(sensor, meter: meter, raw: raw, date: date, latest: input.latest, unit: unit) {
            extra.append(preview)
        }
        return advice(.calibrate, "Calibrate with this value", summary + moment, extra)
    }

    // MARK: Conditions

    static func lowFactor(meter: Double?, sensorMgdL: Double, unit: GlucoseUnit) -> Factor? {
        if let meter, meter < 70 {
            return Factor(id: "low", status: .problem, title: "Low: \(unit.format(mgdL: meter, includeSymbol: true))",
                          detail: "Treat it first. Glucose moves fast after treatment, and sensors are least accurate in lows.",
                          reason: "you're low")
        }
        if meter == nil, sensorMgdL < 70 {
            return Factor(id: "low", status: .problem, title: "The sensor shows a low",
                          detail: "Check with your meter and treat it first.", reason: "the sensor shows a low")
        }
        return nil
    }

    static func trendFactor(rate: Double?, earlier: Double?, unit: GlucoseUnit) -> Factor {
        guard let rate else {
            return Factor(id: "trend", status: .warning, title: "Trend unknown",
                          detail: "Too few readings in the 15 minutes before to tell whether glucose is steady.",
                          reason: "the trend isn't known")
        }
        let speed = abs(rate)
        let rising = rate > 0
        let delay = "Calibrate with a flat arrow: the sensor trails blood by 5–10 minutes, so a meter can read up to "
            + "\(unit.format(mgdL: speed * lagMinutes, includeSymbol: true)) \(rising ? "higher" : "lower") now."
        if speed > fastRate {
            return Factor(id: "trend", status: .problem,
                          title: "\(rising ? "Rising" : "Falling") fast, \(unit.formatRate(mgdLPerMinute: speed))",
                          detail: delay, reason: "glucose is \(rising ? "rising" : "falling") fast")
        }
        if speed >= steadyRate {
            return Factor(id: "trend", status: .problem,
                          title: "\(rising ? "Rising" : "Falling") \(unit.formatRate(mgdLPerMinute: speed))",
                          detail: delay, reason: "glucose is \(rising ? "rising" : "falling")")
        }
        if let earlier, abs(earlier) >= turnRate {
            return Factor(id: "trend", status: .warning, title: "Just levelled off",
                          detail: "Glucose was \(earlier > 0 ? "rising" : "falling") \(unit.formatRate(mgdLPerMinute: abs(earlier))) "
                              + "15 minutes before, and the sensor trails blood by 5–10 minutes.",
                          reason: "glucose has just levelled off")
        }
        return Factor(id: "trend", status: .ok, title: "Glucose steady", detail: unit.formatRate(mgdLPerMinute: rate))
    }

    static func insulinFactor(_ context: LogContext, settlesAt: Date?, time: (Date) -> String) -> Factor {
        func units(_ entry: LogEntry) -> String {
            if case .insulin(let units, _) = entry.kind { return LogEntry.format(units) }
            return ""
        }
        let left = String(format: "%.1f", context.insulinOnBoard)
        // The guide's rule first: no fast insulin in the 2 hours before.
        if let newest = context.workingDoses.last, let minutes = context.minutesSinceInsulin, minutes < LogContext.insulinMinutes {
            return Factor(id: "insulin", status: .problem, title: "Fast insulin \(ago(minutes)) · \(left) U left",
                          detail: "\(units(newest)) U at \(time(newest.date)). Calibrate at least 2 hours after fast insulin: it keeps lowering glucose meanwhile.",
                          reason: "you took fast insulin \(ago(minutes)) (\(left) U still working)")
        }
        guard context.insulinOnBoard >= InsulinOnBoard.activeUnits, let first = context.workingDoses.first else {
            return Factor(id: "insulin", status: .ok, title: "No fast insulin in the last 2 hours",
                          detail: context.workingDoses.last.map { "Last dose \(units($0)) U at \(time($0.date)), mostly used up." } ?? "")
        }
        // A big dose still works after 2 hours.
        let from = context.workingDoses.count == 1
            ? "From \(units(first)) U at \(time(first.date))."
            : "From \(context.workingDoses.count) doses since \(time(first.date))."
        return Factor(id: "insulin", status: context.insulinOnBoard >= waitInsulinUnits ? .problem : .warning,
                      title: "Fast insulin working: \(left) U left",
                      detail: "\(from) It keeps lowering glucose while it works." + (settlesAt.map { " Mostly done around \(time($0))." } ?? ""),
                      reason: "fast insulin is still working (\(left) U)")
    }

    /// How a meal bears on calibrating at `date`, and until when.
    static func foodEffect(_ food: LogEntry, at date: Date) -> (status: Factor.Status, until: Date) {
        let minutes = date.timeIntervalSince(food.date) / 60
        if minutes < LogContext.foodMinutes {
            return (.problem, food.date.addingTimeInterval(LogContext.foodMinutes * 60))
        }
        // 2 to 3 hours after a meal glucose may still be settling. Food without carbs typed counts as one.
        var carbs: Double?
        if case .meal(let grams) = food.kind { carbs = grams }
        return ((carbs ?? .infinity) < 20 ? .ok : .warning, food.date.addingTimeInterval(LogContext.foodLookbackMinutes * 60))
    }

    static func foodFactor(_ context: LogContext) -> Factor {
        // The food that matters most; of equals, the newest.
        let rated = context.foods.map { (food: $0, effect: foodEffect($0, at: context.date)) }
        guard let worst = rated.min(by: { $0.effect.status < $1.effect.status }) else {
            return Factor(id: "food", status: .ok, title: "No food logged in the last 3 hours")
        }
        let minutes = context.date.timeIntervalSince(worst.food.date) / 60
        var carbs = ""
        if case .meal(let grams?) = worst.food.kind { carbs = " (\(LogEntry.format(grams)) g)" }
        let treating = worst.food.text == LogEntry.treatingLowText
        let title = treating ? "Low treated \(ago(minutes))" : "Food \(ago(minutes))\(carbs)"
        let reason = treating ? "you treated a low \(ago(minutes))" : "you ate \(ago(minutes))"
        switch worst.effect.status {
        case .problem:
            return Factor(id: "food", status: .problem, title: title,
                          detail: treating ? "Glucose rises fast after treating a low."
                              : "Calibrate at least 2 hours after eating: glucose rises and falls meanwhile.",
                          reason: reason)
        case .warning:
            return Factor(id: "food", status: .warning, title: title, detail: "Glucose may still be settling.", reason: reason)
        case .ok, .info:
            return Factor(id: "food", status: .ok, title: title)
        }
    }

    static func exerciseFactor(_ context: LogContext) -> Factor? {
        guard let since = context.minutesSinceExercise else { return nil }
        let detail = "Glucose can keep falling for a while after exercise, and the sensor's delay grows."
        if since <= 0 {
            return Factor(id: "exercise", status: .warning, title: "Exercising now", detail: detail, reason: "you're exercising")
        }
        return Factor(id: "exercise", status: .warning, title: "Exercise ended \(ago(since))", detail: detail,
                      reason: "you exercised \(ago(since))")
    }

    /// A jump between two minutes, or readings that jitter a lot: the signal is disturbed.
    static func signalFactor(_ readings: [GlucoseReading], date: Date, unit: GlucoseUnit) -> Factor? {
        let recent = readings.filter { $0.timestamp > date.addingTimeInterval(-15 * 60) && $0.timestamp <= date.addingTimeInterval(60) }
        let jumped = zip(recent, recent.dropFirst()).contains { a, b in
            b.minuteIndex - a.minuteIndex == 1 && abs(b.mgdL - a.mgdL) >= jumpMgdL
        }
        if jumped {
            return Factor(id: "signal", status: .warning, title: "Sudden jump in sensor values",
                          detail: "Pressure on the sensor or a knock can do this. Wait 15 minutes.",
                          reason: "the sensor values jumped")
        }
        let window = readings.filter { $0.timestamp > date.addingTimeInterval(-40 * 60) && $0.timestamp <= date.addingTimeInterval(60) }
        if let noise = SignalStats.noise(in: window), noise.level == .high {
            return Factor(id: "signal", status: .warning, title: "Jumpy readings",
                          detail: "They jump about \(unit.format(mgdL: noise.mgdL, includeSymbol: true)) from minute to minute.",
                          reason: "the readings are jumpy")
        }
        return nil
    }

    /// The guide: no calibration in a sensor's first 12–24 hours, while its signal settles.
    static func dayFactor(_ sensor: CalibrationSensor, date: Date) -> Factor {
        let hours = date.timeIntervalSince(sensor.activatedAt) / 3600
        if hours < youngSensorHours {
            return Factor(id: "day", status: .problem, title: "Sensor only \(Int(hours)) h old",
                          detail: "Its signal is still settling, so a calibration now can make later values wrong.",
                          reason: "the sensor is only \(Int(hours)) h old")
        }
        if hours < Calibration.firstDayHours {
            return Factor(id: "day", status: .warning, title: "Sensor day 1",
                          detail: "Calibrations from its first day count a fifth as much, so one now fades once you calibrate again. Better from tomorrow.",
                          reason: "the sensor is on its first day")
        }
        return Factor(id: "day", status: .ok, title: "Sensor day \(Int(hours / 24) + 1) of \(sensor.lifetimeDays)")
    }

    // MARK: What calibrating would do

    static func calibrationFactor(_ calibration: Calibration, date: Date) -> Factor {
        guard calibration.isCalibrated, let last = calibration.lastCalibration else {
            return Factor(id: "calibration", status: .info, title: "Not calibrated yet",
                          detail: "Values are rough estimates (raw ÷ 8.5) until the first calibration.")
        }
        let hours = date.timeIntervalSince(last) / 3600
        guard hours >= 0 else { return Factor(id: "calibration", status: .info, title: "Last calibration after this time") }
        let when = hours < 1 ? "under an hour ago" : hours < 48 ? "\(Int(hours)) h ago" : "\(Int(hours / 24)) days ago"
        return Factor(id: "calibration", status: .info, title: "Last calibration \(when)")
    }

    /// The guide: sensors drift more on their last day, so check more often then.
    static func lastDayFactor(_ sensor: CalibrationSensor, date: Date) -> Factor? {
        let day = Int(date.timeIntervalSince(sensor.activatedAt) / 86_400) + 1
        guard day >= sensor.lifetimeDays else { return nil }
        return Factor(id: "lastDay", status: .info, title: "The sensor's last day",
                      detail: "Sensors drift more at the end: check more often.")
    }

    /// The accuracy checks since the last calibration (2 days back at most), newest first.
    static func recentChecks(_ sticks: [FingerstickEntry], sensor: CalibrationSensor, date: Date) -> [FingerstickEntry] {
        let start = max(sensor.calibration.lastCalibration ?? sensor.activatedAt, date.addingTimeInterval(-48 * 3600))
        return sticks
            .filter { stick in
                guard stick.sensorSerial == sensor.serial, !stick.usedForCalibration, stick.offeredForCalibration != true,
                      stick.appMgdL != nil else { return false }
                return stick.date > start && stick.date < date
            }
            .sorted { $0.date > $1.date }
    }

    /// What the last checks showed, when they agree with each other.
    static func checksFactor(_ checks: [FingerstickEntry], sensor: CalibrationSensor, difference: Double,
                             meter: Double, unit: GlucoseUnit) -> Factor? {
        let last = Array(checks.prefix(3))
        guard last.count >= 2 else { return nil }
        let differences = last.map { $0.mgdL - ($0.appMgdL ?? $0.mgdL) }
        let off = last.map { !isClose(meterMgdL: $0.mgdL, sensorMgdL: $0.appMgdL ?? $0.mgdL) }
        let period = sensor.calibration.lastCalibration == nil ? "since the sensor started" : "since the last calibration"
        if !off.contains(true) {
            return Factor(id: "checks", status: .info, title: "Your last \(last.count) checks were close to the meter",
                          detail: "All within 15 mg/dL or 15 %, \(period).")
        }
        guard !off.contains(false), differences.allSatisfy({ $0 > 0 }) || differences.allSatisfy({ $0 < 0 }) else { return nil }
        let low = differences[0] > 0
        let too = (difference > 0) == low && !isClose(meterMgdL: meter, sensorMgdL: meter - difference) ? " too" : ""
        let average = unit.format(mgdL: abs(differences.reduce(0, +)) / Double(differences.count), includeSymbol: true)
        return Factor(id: "checks", status: .info, title: "Your last \(last.count) checks read it \(low ? "low" : "high")\(too)",
                      detail: "By \(average) on average, \(period).")
    }

    /// The guide: two calibrations at least 40 mg/dL apart, so the app can fit the slope.
    static func levelFactor(_ levels: [Double], hasSlope: Bool, newLevel: Bool, unit: GlucoseUnit) -> Factor? {
        guard !levels.isEmpty, !hasSlope else { return nil }
        let apart = unit.format(mgdL: Calibration.minimumSpreadMgdL, includeSymbol: true)
        if newLevel {
            return Factor(id: "level", status: .info, title: "A second level for the calibration",
                          detail: "Your calibrations so far were near \(levelText(levels, unit: unit)). One at least \(apart) away lets the app fit how the sensor scales with glucose, not just shift every value.")
        }
        return Factor(id: "level", status: .info, title: "One calibration level so far",
                      detail: "For the slope, calibrate once more with glucose steady and at least \(apart) away from \(levelText(levels, unit: unit)).")
    }

    /// What the newest reading becomes with this fingerstick in the calibration.
    static func previewFactor(_ sensor: CalibrationSensor, meter: Double, raw: Double, date: Date,
                              latest: GlucoseReading?, unit: GlucoseUnit) -> Factor? {
        guard let latest, latest.sensorSerial == sensor.serial, let latestRaw = latest.raw else { return nil }
        let points = sensor.calibrationPoints + [CalibrationPoint(date: date, referenceMgdL: meter, raw: raw)]
        // Fitted as the sensor's own calibration is: as of the newest point, first-day points counting less.
        let calibration = Calibration.fit(points, now: points.map(\.date).max() ?? date,
                                          firstDayEnds: sensor.activatedAt.addingTimeInterval(Calibration.firstDayHours * 3600))
        guard let after = ReadingPipeline.clamped(calibration.mgdL(fromRaw: latestRaw).rounded()),
              abs(after - latest.mgdL) >= 1 else { return nil }
        return Factor(id: "preview", status: .info,
                      title: "After calibrating: \(unit.formatReading(mgdL: latest.mgdL)) becomes about \(unit.formatReading(mgdL: after))",
                      detail: "The newest reading. Values from the last 30 minutes and new ones change the same way.")
    }

    // MARK: Text

    static func cannot(_ reason: String) -> CalibrationAdvice {
        CalibrationAdvice(verdict: .cannot, title: "Can't calibrate now", summary: reason, factors: [])
    }

    /// The calibrations' level, for "near 120 mg/dL".
    static func levelText(_ levels: [Double], unit: GlucoseUnit) -> String {
        unit.format(mgdL: levels.reduce(0, +) / Double(max(levels.count, 1)), includeSymbol: true)
    }

    /// "40 min ago", "2 h 5 min ago".
    static func ago(_ minutes: Double) -> String {
        let total = Int(minutes.rounded())
        if total < 1 { return "just now" }
        if total < 60 { return "\(total) min ago" }
        return total % 60 == 0 ? "\(total / 60) h ago" : "\(total / 60) h \(total % 60) min ago"
    }

    /// Reasons joined into the start of a sentence: "Fast insulin is still working and glucose is falling".
    static func sentence(_ reasons: [String]) -> String {
        let text = reasons.joined(separator: " and ")
        return text.prefix(1).uppercased() + text.dropFirst()
    }
}
