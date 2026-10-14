import XCTest
@testable import GlucoseCore

final class CalibrationAdviceTests: XCTestCase {
    private let now = TestSupport.noon

    private func ago(_ minutes: Double) -> Date {
        now.addingTimeInterval(-minutes * 60)
    }

    /// A sensor started `startedHoursAgo` ago, calibrated 10 hours ago at 120 mg/dL so that a value
    /// is its raw signal ÷ 8.5 (or never calibrated).
    private func sensor(calibrated: Bool = true, startedHoursAgo: Double = 72,
                        pending: CalibrationPoint? = nil) -> CalibrationSensor {
        let activatedAt = ago(startedHoursAgo * 60)
        let points = calibrated ? [CalibrationPoint(date: ago(600), referenceMgdL: 120, raw: 1020)] : []
        return CalibrationSensor(serial: "TEST", activatedAt: activatedAt, warmUpEndsAt: activatedAt.addingTimeInterval(3600),
                                 lifetimeDays: 15, calibration: Calibration.fit(points, now: ago(600)),
                                 calibrationPoints: points, unconfirmedPoint: pending)
    }

    /// One reading a minute for `count` minutes up to `endingAgo` minutes before now, valued by
    /// `value(minutes before now)`, with the raw signal that gives that value.
    private func readings(count: Int = 45, endingAgo: Int = 0, startedHoursAgo: Double = 72,
                          _ value: (Int) -> Double) -> [GlucoseReading] {
        let nowMinute = Int(startedHoursAgo * 60)
        return (endingAgo..<(endingAgo + count)).reversed().map { back in
            let mgdL = value(back)
            return GlucoseReading(sensorSerial: "TEST", minuteIndex: nowMinute - back, timestamp: ago(Double(back)),
                                  mgdL: mgdL, source: .bluetooth, raw: mgdL * 8.5)
        }
    }

    private func flat(_ mgdL: Double) -> [GlucoseReading] {
        readings { _ in mgdL }
    }

    private func check(_ meter: Double, shown: Double, minutesAgo: Double) -> FingerstickEntry {
        FingerstickEntry(date: ago(minutesAgo), mgdL: meter, usedForCalibration: false, sensorSerial: "TEST", appMgdL: shown)
    }

    private func advise(meter: Double?, readings: [GlucoseReading], logbook: [LogEntry] = [],
                        sensor: CalibrationSensor? = nil, fingersticks: [FingerstickEntry] = [],
                        at date: Date? = nil, isDemo: Bool = false) -> CalibrationAdvice {
        var input = CalibrationAdviceInput(date: date ?? now, meterMgdL: meter, sensor: sensor ?? self.sensor())
        input.readings = readings
        input.latest = readings.last
        input.logbook = logbook
        input.fingersticks = fingersticks
        input.isDemo = isDemo
        return CalibrationAdvisor.advise(input, unit: .mgdL) { _ in "12:00" }
    }

    private func factor(_ id: String, in advice: CalibrationAdvice) -> CalibrationAdvice.Factor? {
        advice.factors.first { $0.id == id }
    }

    // MARK: How far off the sensor is

    func testFarOffAndSteadySaysCalibrate() {
        let advice = advise(meter: 155, readings: flat(120))
        XCTAssertEqual(advice.verdict, .calibrate)
        XCTAssertEqual(advice.recommendsCalibrating, true)
        XCTAssertTrue(advice.summary.hasPrefix("The sensor reads 35 mg/dL low (23 %), more than 20 % off."), advice.summary)
        XCTAssertEqual(factor("difference", in: advice)?.title, "Sensor 120, meter 155 mg/dL")
        XCTAssertEqual(factor("trend", in: advice)?.status, .ok)
        // The calibration from 10 hours ago still weighs in: 120 becomes about 140, not 155.
        XCTAssertEqual(factor("preview", in: advice)?.title, "After calibrating: 120 becomes about 140")
    }

    func testCloseToTheMeterNeedsNoCalibration() {
        let advice = advise(meter: 130, readings: flat(120))
        XCTAssertEqual(advice.verdict, .notNeeded)
        XCTAssertEqual(advice.recommendsCalibrating, false)
        XCTAssertNil(factor("preview", in: advice))
        XCTAssertEqual(factor("level", in: advice)?.title, "One calibration level so far", "the guide wants a second level")
    }

    func testALittleOffSaysCheckAgain() {
        // 17 %: orange under Accuracy, which can be meter error.
        let advice = advise(meter: 145, readings: flat(120))
        XCTAssertEqual(advice.verdict, .checkAgain)
        XCTAssertEqual(advice.recommendsCalibrating, false)
        XCTAssertTrue(advice.summary.hasPrefix("The sensor reads 25 mg/dL low (17 %). That can be meter error"), advice.summary)
    }

    func testALittleOffAgainAfterACheckOffTheSameWayCalibrates() {
        let advice = advise(meter: 145, readings: flat(120), fingersticks: [check(140, shown: 118, minutesAgo: 120)])
        XCTAssertEqual(advice.verdict, .calibrate)
        XCTAssertTrue(advice.summary.hasPrefix("The sensor reads 25 mg/dL low (17 %), and your last check was off the same way."),
                      advice.summary)
    }

    func testFirstCalibrationIsWorthItEvenWhenClose() {
        let advice = advise(meter: 124, readings: flat(120), sensor: sensor(calibrated: false))
        XCTAssertEqual(advice.verdict, .calibrate)
        XCTAssertTrue(advice.summary.hasPrefix("Values are rough estimates"), advice.summary)
        XCTAssertEqual(factor("calibration", in: advice)?.title, "Not calibrated yet")
    }

    func testSecondLevelIsWorthItEvenWhenClose() {
        // Calibrated at 120 only; at 170 the app can fit the slope.
        let advice = advise(meter: 170, readings: flat(165))
        XCTAssertEqual(advice.verdict, .calibrate)
        XCTAssertEqual(factor("level", in: advice)?.title, "A second level for the calibration")
    }

    // MARK: Glucose moving

    func testInsulinAnHourBeforeSaysWait() {
        let insulin = LogEntry(date: ago(60), kind: .insulin(units: 4, type: .rapid))
        let advice = advise(meter: 155, readings: flat(120), logbook: [insulin])
        XCTAssertEqual(advice.verdict, .wait)
        XCTAssertEqual(advice.recommendsCalibrating, false)
        XCTAssertTrue(advice.summary.hasPrefix("You took fast insulin 1 h ago (3.1 U still working)."), advice.summary)
        XCTAssertTrue(advice.summary.hasSuffix("calibrate when glucose is steady, around 12:00."), advice.summary)
        let working = factor("insulin", in: advice)
        XCTAssertEqual(working?.status, .problem)
        XCTAssertEqual(working?.title, "Fast insulin 1 h ago · 3.1 U left")
    }

    func testEvenASmallDoseInTheLastTwoHoursSaysWait() {
        let insulin = LogEntry(date: ago(100), kind: .insulin(units: 0.5, type: .rapid))
        let advice = advise(meter: 155, readings: flat(120), logbook: [insulin])
        XCTAssertEqual(factor("insulin", in: advice)?.status, .problem, "the guide: no fast insulin in the 2 hours before")
        XCTAssertEqual(advice.verdict, .wait)
    }

    func testABigDoseStillWorkingAfterTwoHoursSaysWait() {
        let insulin = LogEntry(date: ago(150), kind: .insulin(units: 8, type: .rapid))
        let advice = advise(meter: 155, readings: flat(120), logbook: [insulin])
        XCTAssertEqual(factor("insulin", in: advice)?.title, "Fast insulin working: 2.1 U left")
        XCTAssertEqual(advice.verdict, .wait)
    }

    func testSlowInsulinDoesNotStopACalibration() {
        let basal = LogEntry(date: ago(60), kind: .insulin(units: 14, type: .long))
        XCTAssertEqual(advise(meter: 155, readings: flat(120), logbook: [basal]).verdict, .calibrate)
    }

    func testFastFallSaysWait() {
        // Down 2.5 mg/dL a minute to 120 now; the meter's 100 is mostly that the sensor lags.
        let advice = advise(meter: 100, readings: readings { 120 + 2.5 * Double($0) })
        XCTAssertEqual(advice.verdict, .wait)
        XCTAssertEqual(factor("trend", in: advice)?.title, "Falling fast, 2.5 mg/dL/min")
        XCTAssertTrue(advice.summary.hasPrefix("Most of the 20 mg/dL difference is the sensor's 5–10 minute delay while glucose falls."),
                      advice.summary)
    }

    func testAnyArrowSaysWait() {
        // Rising 1.5 a minute: not a flat arrow.
        let advice = advise(meter: 145, readings: readings { 120 - 1.5 * Double($0) })
        XCTAssertEqual(factor("trend", in: advice)?.status, .problem)
        XCTAssertEqual(advice.verdict, .wait)
        XCTAssertTrue(advice.summary.hasPrefix("Most of the 25 mg/dL difference is the sensor's 5–10 minute delay while glucose rises."),
                      advice.summary)
    }

    func testRecentMealSaysWait() {
        let meal = LogEntry(date: ago(40), kind: .meal(carbsGrams: 50))
        let advice = advise(meter: 155, readings: flat(120), logbook: [meal])
        XCTAssertEqual(advice.verdict, .wait)
        XCTAssertTrue(advice.summary.hasPrefix("You ate 40 min ago."), advice.summary)
        XCTAssertEqual(factor("food", in: advice)?.title, "Food 40 min ago (50 g)")
    }

    func testEvenASnackInTheLastTwoHoursSaysWait() {
        let snack = LogEntry(date: ago(30), kind: .meal(carbsGrams: 5))
        XCTAssertEqual(advise(meter: 155, readings: flat(120), logbook: [snack]).verdict, .wait)
    }

    func testAMealTwoToThreeHoursBeforeOnlyWarns() {
        let meal = LogEntry(date: ago(150), kind: .meal(carbsGrams: 30))
        let advice = advise(meter: 155, readings: flat(120), logbook: [meal])
        XCTAssertEqual(factor("food", in: advice)?.status, .warning)
        XCTAssertEqual(advice.verdict, .calibrate)
        XCTAssertTrue(advice.summary.hasSuffix("Now is good enough, though you ate 2 h 30 min ago."), advice.summary)
    }

    func testTwoWarningsSayWait() {
        // The sensor's first day and a meal 2.5 hours ago: each alone is fine, together a reason to wait.
        let meal = LogEntry(date: ago(150), kind: .meal(carbsGrams: 30))
        let advice = advise(meter: 155, readings: readings(startedHoursAgo: 18) { _ in 120 }, logbook: [meal],
                            sensor: sensor(startedHoursAgo: 18))
        XCTAssertEqual(factor("day", in: advice)?.status, .warning)
        XCTAssertEqual(advice.verdict, .wait)
    }

    func testExerciseWarns() {
        let walk = LogEntry(date: ago(50), kind: .exercise(minutes: 30))
        let exercise = factor("exercise", in: advise(meter: 155, readings: flat(120), logbook: [walk]))
        XCTAssertEqual(exercise?.status, .warning)
        XCTAssertEqual(exercise?.title, "Exercise ended 20 min ago")
    }

    func testJustLevelledOffWarns() {
        // Rising 2 a minute until 15 minutes ago, flat since.
        let advice = advise(meter: nil, readings: readings { $0 < 15 ? 150 : 150 - 2 * Double($0 - 15) })
        XCTAssertEqual(factor("trend", in: advice)?.title, "Just levelled off")
        XCTAssertEqual(factor("trend", in: advice)?.status, .warning)
    }

    func testSuddenJumpWarns() {
        let advice = advise(meter: nil, readings: readings { $0 <= 5 ? 135 : 120 })
        XCTAssertEqual(factor("signal", in: advice)?.title, "Sudden jump in sensor values")
    }

    // MARK: Not now, or not at all

    func testNewSensorSaysDontCalibrateYet() {
        let advice = advise(meter: 155, readings: readings(startedHoursAgo: 6) { _ in 120 },
                            sensor: sensor(calibrated: false, startedHoursAgo: 6))
        XCTAssertEqual(advice.verdict, .wait)
        XCTAssertEqual(advice.title, "Don't calibrate yet")
        XCTAssertTrue(advice.summary.hasPrefix("The sensor is only 6 h old: don't calibrate in its first 12–24 hours."), advice.summary)
        XCTAssertEqual(factor("day", in: advice)?.title, "Sensor only 6 h old")
    }

    func testLowSaysTreatFirst() {
        let advice = advise(meter: 60, readings: flat(65))
        XCTAssertEqual(advice.verdict, .wait)
        XCTAssertEqual(advice.title, "Treat the low first")
    }

    func testFarOffValueSaysTestAgain() {
        let advice = advise(meter: 200, readings: flat(120))
        XCTAssertEqual(advice.verdict, .testAgain)
        XCTAssertNil(advice.recommendsCalibrating, "only an offered fingerstick waits for a second one")
        XCTAssertTrue(advice.summary.contains("Wash and dry your hands"), advice.summary)
    }

    func testSecondFarOffValueThatAgreesCalibrates() {
        let pending = CalibrationPoint(date: ago(10), referenceMgdL: 198, raw: 1020)
        let advice = advise(meter: 200, readings: flat(120), sensor: sensor(pending: pending))
        XCTAssertEqual(advice.verdict, .calibrate)
        XCTAssertTrue(advice.summary.hasPrefix("It agrees with your fingerstick at 12:00"), advice.summary)
    }

    func testWarmUpCannotCalibrate() {
        let advice = advise(meter: 155, readings: readings(count: 20, startedHoursAgo: 0.5) { _ in 120 },
                            sensor: sensor(calibrated: false, startedHoursAgo: 0.5))
        XCTAssertEqual(advice.verdict, .cannot)
        XCTAssertTrue(advice.summary.contains("warming up"), advice.summary)
    }

    func testNoReadingNearTheTimeCannotCalibrate() {
        let advice = advise(meter: 155, readings: readings(endingAgo: 10) { _ in 120 })
        XCTAssertEqual(advice.verdict, .cannot)
        XCTAssertEqual(advice.summary, "There's no sensor value within 3 minutes of that time.")
    }

    // MARK: The moment, the past, the checks and the demo

    func testBeforeTheValueIsTypedOnlyTheMomentCounts() {
        let good = advise(meter: nil, readings: flat(120))
        XCTAssertEqual(good.verdict, .calibrate)
        XCTAssertEqual(good.title, "Good time to calibrate")
        XCTAssertNil(factor("difference", in: good))

        let insulin = LogEntry(date: ago(60), kind: .insulin(units: 4, type: .rapid))
        let bad = advise(meter: nil, readings: flat(120), logbook: [insulin])
        XCTAssertEqual(bad.verdict, .wait)
        XCTAssertEqual(bad.title, "Not a good time to calibrate")
        XCTAssertTrue(bad.summary.hasSuffix("Calibrate when glucose is steady, around 12:00."), bad.summary)
    }

    func testBackdatedFingerstickIsJudgedAtItsTime() {
        // Flat until 30 minutes ago, rising fast since: a fingerstick from 35 minutes ago was steady.
        let series = readings { $0 >= 30 ? 120 : 120 + 3 * Double(30 - $0) }
        let advice = advise(meter: 155, readings: series, at: ago(35))
        XCTAssertEqual(factor("trend", in: advice)?.status, .ok)
        XCTAssertEqual(advice.verdict, .calibrate)
    }

    func testChecksSinceTheLastCalibrationThatReadLow() {
        let checks = [check(140, shown: 118, minutesAgo: 180), check(138, shown: 117, minutesAgo: 60)]
        let summary = factor("checks", in: advise(meter: 155, readings: flat(120), fingersticks: checks))
        XCTAssertEqual(summary?.title, "Your last 2 checks read it low too")
        XCTAssertEqual(summary?.detail, "By 22 mg/dL on average, since the last calibration.")
    }

    func testANewLevelLetsTheSlopeBeFitted() {
        // 17 % off would only be a reason to check again, but at a new level it's worth calibrating.
        let advice = advise(meter: 180, readings: flat(150))
        XCTAssertEqual(advice.verdict, .calibrate)
        XCTAssertTrue(advice.summary.hasPrefix("Your calibrations so far were near 120 mg/dL"), advice.summary)
    }

    func testLastDayAsksForMoreChecks() {
        let advice = advise(meter: 130, readings: readings(startedHoursAgo: 348) { _ in 120 }, sensor: sensor(startedHoursAgo: 348))
        XCTAssertEqual(factor("lastDay", in: advice)?.title, "The sensor's last day")
    }

    func testDemoJudgesWithoutRawValues() {
        let demo = flat(120).map { GlucoseReading(sensorSerial: $0.sensorSerial, minuteIndex: $0.minuteIndex,
                                                   timestamp: $0.timestamp, mgdL: $0.mgdL, source: .simulated) }
        let sensor = CalibrationSensor(serial: "TEST", activatedAt: ago(72 * 60), warmUpEndsAt: ago(71 * 60),
                                       lifetimeDays: 15, calibration: Calibration(pointCount: 1))
        let advice = advise(meter: 155, readings: demo, sensor: sensor, isDemo: true)
        XCTAssertEqual(advice.verdict, .calibrate)
        XCTAssertEqual(advice.factors.last?.id, "demo")
        XCTAssertNil(factor("preview", in: advice))
    }

    func testBandsMatchTheAccuracyScreen() {
        XCTAssertTrue(CalibrationAdvisor.isClose(meterMgdL: 80, sensorMgdL: 94), "14 mg/dL below 100")
        XCTAssertFalse(CalibrationAdvisor.isClose(meterMgdL: 80, sensorMgdL: 97))
        XCTAssertTrue(CalibrationAdvisor.isClose(meterMgdL: 200, sensorMgdL: 172), "14 %")
        XCTAssertFalse(CalibrationAdvisor.isFarOff(meterMgdL: 200, sensorMgdL: 165), "17.5 % is a little off")
        XCTAssertTrue(CalibrationAdvisor.isFarOff(meterMgdL: 200, sensorMgdL: 155))
    }

    func testOutlierNeedsBothGaps() {
        XCTAssertFalse(Calibration.isOutlier(referenceMgdL: 165, sensorMgdL: 120), "45 mg/dL, but under 40 %")
        XCTAssertTrue(Calibration.isOutlier(referenceMgdL: 200, sensorMgdL: 120))
        XCTAssertTrue(Calibration.isOutlier(referenceMgdL: 50, sensorMgdL: 100))
        XCTAssertFalse(Calibration.isOutlier(referenceMgdL: 70, sensorMgdL: 40), "40 % off, but only 30 mg/dL")
    }
}
