import Foundation
import Observation
import SwiftUI
import UIKit
import GlucoseCore
import LibreProtocol

/// App state and the reading pipeline: source → merge/store → alerts → notifications and surfaces.
@MainActor
@Observable
final class AppModel {
    var settings: AppSettings
    private(set) var readings: [GlucoseReading] = []
    private(set) var recentEvents: [AlertEvent] = []
    private(set) var logbook: [LogEntry] = []
    private(set) var fingersticks: [FingerstickEntry] = []
    private(set) var signatureExpiry: Date?
    var lastError: String?
    var isLocked = false
    /// Whether iOS lets alerts marked Critical sound through Silent mode and Focus.
    private(set) var criticalAlertsAllowed = false
    /// Whether Time Sensitive notifications are on, so alerts show during Focus.
    private(set) var timeSensitiveAllowed = true
    /// Why alerts can't be seen or heard (notifications or their sounds turned off), if so.
    private(set) var notificationProblem: String?
    let sensor: SensorConnection

    /// Readings kept in memory (enough for 14-day reports).
    static let memoryDays: Double = 14
    /// Readings, notes, fingersticks and raw captures kept on the phone. Older data is deleted.
    static let archiveDays: Double = 91

    @ObservationIgnored private var engine: AlertEngine
    @ObservationIgnored let stores: AppStores
    @ObservationIgnored let notifications = NotificationService()
    @ObservationIgnored private let voice = VoiceAnnouncer()
    @ObservationIgnored private let alarm = AlarmPlayer()
    @ObservationIgnored let surfaces = SurfaceUpdater()
    @ObservationIgnored private var demoTask: Task<Void, Never>?
    @ObservationIgnored private var demoMinute = 0
    @ObservationIgnored private let demoSensor: SimulatedSensor
    @ObservationIgnored private var started = false
    @ObservationIgnored private var savedSettings: AppSettings
    @ObservationIgnored private var batteryAlerted = false
    @ObservationIgnored private var isActive = true
    @ObservationIgnored private var batteryObserver: NSObjectProtocol?
    @ObservationIgnored private var lastPrune = Date.distantPast
    /// True while the sensor connection is stopped because the app is closed and "Run in background" is off.
    private(set) var pausedInBackground = false

    init() {
        let stores = AppStores()
        self.stores = stores
        var settings = stores.settings.load() ?? AppSettings()
        if ScreenshotMode.isActive {
            settings.onboardingDone = !ScreenshotMode.showsOnboarding
            settings.dataSource = .demo
        }
        self.settings = settings
        self.savedSettings = settings
        self.engine = AlertEngine(ruleSet: settings.ruleSet)
        // Snoozes, repeats and the decision log survive iOS relaunching the app.
        if settings.dataSource == .libre, !ScreenshotMode.isActive, let saved = stores.alertState.load() {
            engine.restore(saved, now: Date())
        }
        let now = Date()
        self.demoSensor = SimulatedSensor(startedAt: Date(timeIntervalSince1970: (now.timeIntervalSince1970 / 60).rounded(.down) * 60 - 15 * 86_400))
        self.sensor = SensorConnection(stores: stores)
        self.logbook = stores.logbook.load() ?? []
        self.fingersticks = stores.fingersticks.load() ?? []
        sensor.allowUnverifiedTypes = settings.allowUnverifiedSensorTypes
        sensor.recordAllRawData = settings.recordAllRawData

        sensor.onReadings = { [weak self] readings, live in self?.ingest(readings, live: live) }
        sensor.onEvent = { [weak self] event in self?.handleSensorEvent(event) }
        notifications.onSnooze = { [weak self] id, sentAt in self?.acknowledge(ruleID: id, eventDate: sentAt) }
    }

    // MARK: Derived state

    var unit: GlucoseUnit { settings.unit }
    var latest: GlucoseReading? { readings.last }
    var decisionLog: [String] { engine.log.reversed() }
    var isDemo: Bool { settings.dataSource == .demo }

    var trendArrow: TrendArrow {
        guard let latest, Date().timeIntervalSince(latest.timestamp) < 15 * 60 || isDemo else { return .unknown }
        return Trend.arrow(forRate: Trend.ratePerMinute(readings(lastHours: 0.5)))
    }

    /// True when the newest value is too old to show as current.
    var isStale: Bool {
        guard let latest else { return true }
        return !isDemo && Date().timeIntervalSince(latest.timestamp) > 10 * 60
    }

    /// Missing readings in the last 24 hours, e.g. after the phone was out of range.
    /// "No data right now" isn't included; the stale-value banner covers that.
    var readingGap: DateInterval? {
        guard !isDemo, sensor.record != nil else { return nil }
        let now = Date()
        guard let gap = ReadingPipeline.recentGap(in: readings, now: now, minimumMinutes: 20, lookbackHours: 24),
              gap.end < now.addingTimeInterval(-60) else { return nil }
        return gap
    }

    /// The sensor keeps 8 hours of history, so a gap that started within that window can be filled by NFC.
    func canFillWithNFC(_ gap: DateInterval) -> Bool {
        gap.start > Date().addingTimeInterval(-8 * 3600 + 15 * 60)
    }

    func readings(lastHours hours: Double) -> [GlucoseReading] {
        guard let end = latest?.timestamp else { return [] }
        let start = end.addingTimeInterval(-hours * 3600)
        return readings.filter { $0.timestamp >= start }
    }

    func readings(in interval: DateInterval) -> [GlucoseReading] {
        readings.filter { interval.contains($0.timestamp) }
    }

    /// Readings beyond the 14 days held in memory come from the archive.
    func archivedReadings(in interval: DateInterval) -> [GlucoseReading] {
        guard !isDemo, let archive = stores.archive,
              interval.start < Date().addingTimeInterval(-Self.memoryDays * 86_400) else { return readings(in: interval) }
        return (try? archive.load(from: interval.start, to: interval.end)) ?? []
    }

    // MARK: Startup

    func start() async {
        guard !started else { return }
        started = true
        if !ScreenshotMode.isActive {
            await notifications.requestAuthorization()
            await refreshNotificationStatus()
        }
        signatureExpiry = ProvisioningProfile.expirationDate()
        notifications.scheduleSignatureReminders(expiry: signatureExpiry)
        startBatteryMonitoring()
        if settings.biometricLock {
            isLocked = true
            await unlock()
        }
        activateSource()
        pruneOldData()
    }

    /// Starts the chosen data source. `resetEngine` is for a change of data source: alerts from
    /// the demo and the real sensor must not mix. Pairing again or restoring a backup keeps the
    /// alert engine, so a snooze isn't lost and a low already announced doesn't alarm again as new.
    func activateSource(resetEngine: Bool = false) {
        demoTask?.cancel()
        notifications.cancelDemoAlerts()
        if resetEngine {
            engine = AlertEngine(ruleSet: settings.ruleSet)
            stores.alertState.delete()
            recentEvents = []
            alarm.stop()
        } else {
            engine.ruleSet = settings.ruleSet
        }
        switch settings.dataSource {
        case .demo:
            sensor.stop()
            notifications.cancelMissingData()
            startDemo()
        case .libre:
            let now = Date()
            readings = (try? stores.archive?.load(from: now.addingTimeInterval(-Self.memoryDays * 86_400),
                                                  to: now.addingTimeInterval(3600))) ?? []
            // Trend alerts need the last minutes of history, not just the next live readings.
            engine.addHistory(readings(lastHours: 0.5))
            sensor.start()
            if let record = sensor.record {
                notifications.scheduleSensorReminders(SensorLifecycle.reminders(expiresAt: record.expiresAt, now: now))
            }
        }
    }

    private func startDemo() {
        demoMinute = Int(Date().timeIntervalSince(demoSensor.startedAt) / 60)
        readings = demoSensor.readings(minutes: max(0, demoMinute - 14 * 1440)..<demoMinute)
        let simulated = demoSensor
        sensor.startDemoInspector(startedAt: demoSensor.startedAt, currentMinute: demoMinute) { minute in
            Int((simulated.reading(atMinute: minute).mgdL * 8.5).rounded())
        }
        if ScreenshotMode.isActive {
            seedSampleData()
        }
        let speed = settings.demoSpeed
        demoTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: speed.interval)
                guard let self, !Task.isCancelled else { return }
                let reading = self.demoSensor.reading(atMinute: self.demoMinute)
                self.sensor.simulatePacket(ageMinutes: self.demoMinute)
                self.demoMinute += 1
                self.ingest([reading], live: true)
            }
        }
    }

    /// Example notes, fingersticks and alerts for the CI screenshots. Kept in memory only.
    private func seedSampleData() {
        guard let end = readings.last?.timestamp else { return }
        func ago(_ minutes: Double) -> Date { end.addingTimeInterval(-minutes * 60) }
        sensor.seedSampleHistory(now: end)
        if sensor.saved.isEmpty, let packet = sensor.packets.first {
            sensor.keep(packet, reason: "Saved by you (example)")
        }
        logbook = [
            LogEntry(date: ago(25), kind: .insulin(units: 4, type: .rapid), text: "Correction"),
            LogEntry(date: ago(95), kind: .exercise(minutes: 40), text: "Walk"),
            LogEntry(date: ago(170), kind: .meal(carbsGrams: 60), text: "Lunch: pasta"),
            LogEntry(date: ago(172), kind: .insulin(units: 6, type: .rapid), text: ""),
            LogEntry(date: ago(600), kind: .insulin(units: 14, type: .long), text: "Evening basal"),
            LogEntry(date: ago(640), kind: .meal(carbsGrams: 45), text: "Dinner"),
            LogEntry(date: ago(900), kind: .note, text: "Slept badly, a bit stressed"),
        ]
        fingersticks = [
            FingerstickEntry(date: ago(60), mgdL: (readings(lastHours: 1.1).first?.mgdL ?? 110) + 6, usedForCalibration: false),
            FingerstickEntry(date: ago(480), mgdL: 124, usedForCalibration: true),
        ]
        let rules = settings.ruleSet.rules
        if let low = rules.first(where: { $0.name == "Lower" }), let high = rules.first(where: { $0.name == "High" }) {
            recentEvents = [
                AlertEvent(ruleID: low.id, ruleName: low.name, direction: .low, valueMgdL: 68, date: ago(130),
                           sound: low.sound, isCritical: false, criticalVolume: 1, kind: .initial),
                AlertEvent(ruleID: high.id, ruleName: high.name, direction: .high, valueMgdL: 186, date: ago(260),
                           sound: high.sound, isCritical: false, criticalVolume: 1, kind: .initial),
            ]
        }
    }

    /// Readings for the home chart: full resolution for the last 3 hours, one per 5 minutes before that.
    var chartReadings: [GlucoseReading] {
        guard let latest else { return [] }
        let detailedFrom = latest.timestamp.addingTimeInterval(-3 * 3600)
        var result: [GlucoseReading] = []
        result.reserveCapacity(5000)
        var lastKept = Date.distantPast
        for reading in readings where reading.timestamp >= detailedFrom || reading.timestamp.timeIntervalSince(lastKept) >= 300 {
            result.append(reading)
            lastKept = reading.timestamp
        }
        return result
    }

    // MARK: Reading pipeline

    func ingest(_ incoming: [GlucoseReading], live: Bool) {
        let valid = incoming.filter(ReadingPipeline.isPlausible)
        guard !valid.isEmpty else { return }
        let previousLatest = readings.last?.timestamp
        let known = Set(readings.map(\.id))
        let fresh = valid.filter { !known.contains($0.id) }

        readings = ReadingPipeline.merge(readings, with: valid)
        if let newest = readings.last?.timestamp {
            let cutoff = newest.addingTimeInterval(-Self.memoryDays * 86_400)
            if let first = readings.firstIndex(where: { $0.timestamp >= cutoff }), first > 0 {
                readings.removeFirst(first)
            }
        }
        if !isDemo, !fresh.isEmpty {
            do {
                try stores.archive?.append(fresh)
            } catch {
                lastError = "Couldn't save readings: \(error.localizedDescription)"
            }
            if Date().timeIntervalSince(lastPrune) > 86_400 {
                pruneOldData()
            }
        }

        // Backfilled minutes give the trend alerts a full 15-minute window right after a reconnect.
        engine.addHistory(fresh)

        guard live, let latest = readings.last, valid.contains(where: { $0.id == latest.id }) else { return }
        let isNewer = previousLatest.map { latest.timestamp > $0 } ?? true
        guard isNewer else { return }

        // Don't alert on old values that arrive late (backfill after a long gap).
        if latest.source == .simulated || Date().timeIntervalSince(latest.timestamp) < 10 * 60 {
            let before = (engine.states, engine.trendStates)
            let events = engine.process(latest)
            // A demo in the background already has its alerts scheduled (see scheduleDemoAlertsAhead).
            deliver(events, notify: !(demoRunsAhead && !isActive))
            saveAlertState(force: !events.isEmpty || before.0 != engine.states || before.1 != engine.trendStates)
        }
        // In the background the demo stops when iOS suspends the app, which isn't missing data.
        if !isDemo || (settings.demoSpeed == .realTime && isActive) {
            let warmUp = isDemo ? nil : sensor.record?.warmUpEndsAt
            notifications.scheduleMissingData(settings.missingData.fireDates(lastReading: latest.timestamp, warmUpEnds: warmUp),
                                              config: settings.missingData)
        }
        surfaces.update(latest: latest, arrow: trendArrow, recent: readings(lastHours: 3), unit: unit,
                        liveActivityEnabled: settings.liveActivity)
    }

    private func deliver(_ events: [AlertEvent], notify: Bool = true) {
        guard !events.isEmpty else { return }
        for event in events where notify {
            let alarmPlaying = playAlarmIfNeeded(event)
            notifications.deliver(event, unit: unit, alarmPlaying: alarmPlaying)
            if settings.speakValues, isActive, !alarmPlaying {
                voice.announce(event, unit: unit)
            }
        }
        recentEvents.insert(contentsOf: events.reversed(), at: 0)
        if recentEvents.count > 50 {
            recentEvents.removeLast(recentEvents.count - 50)
        }
    }

    // MARK: Demo while the phone is locked

    /// A real-time demo whose alerts are scheduled ahead while the app is off screen.
    private var demoRunsAhead: Bool { isDemo && settings.demoSpeed == .realTime && demoTask != nil }

    /// iOS suspends the app soon after it leaves the screen, and the demo has no Bluetooth to wake it.
    /// The simulated sensor is predictable, so the alerts it will raise are worked out now and scheduled.
    private func scheduleDemoAlertsAhead() {
        guard demoRunsAhead else { return }
        notifications.cancelMissingData()
        var future = engine
        var events: [AlertEvent] = []
        var minute = demoMinute
        while events.count < NotificationService.maxDemoAlerts, minute < demoMinute + 12 * 60 {
            events += future.process(demoSensor.reading(atMinute: minute))
            minute += 1
        }
        notifications.scheduleDemoAlerts(events, unit: unit)
    }

    /// Back on screen: drop the scheduled demo alerts and catch up on the minutes missed while suspended.
    /// The scheduled notifications already announced those minutes' alerts, so they're only listed.
    private func catchUpDemo() {
        notifications.cancelDemoAlerts()
        guard demoRunsAhead else { return }
        let current = Int(Date().timeIntervalSince(demoSensor.startedAt) / 60)
        guard current > demoMinute else { return }
        let missed = demoSensor.readings(minutes: demoMinute..<current)
        demoMinute = current
        ingest(missed, live: false)
        deliver(missed.flatMap { engine.process($0) }, notify: false)
    }

    /// A Critical alert plays from the app while iOS won't let its notification through Silent and Focus.
    private func playAlarmIfNeeded(_ event: AlertEvent, seconds: Double = 30) -> Bool {
        guard event.isCritical, !notifications.criticalAllowed else { return false }
        let style = event.sound == .silent
            ? SoundStyle.tune(name: event.direction == .low ? "alarm_loud_low" : "alarm_high")
            : event.sound
        return alarm.play(style, seconds: seconds)
    }

    /// Sends a rule's alert right away, exactly as it would sound, without logging it.
    func sendTestAlert(for rule: AlertRule) {
        let event = AlertEvent(ruleID: rule.id, ruleName: "Test: \(rule.name)", direction: rule.direction,
                               valueMgdL: rule.thresholdMgdL, date: Date(), sound: rule.sound,
                               isCritical: rule.isCritical, criticalVolume: rule.criticalVolume, kind: .initial)
        notifications.deliver(event, unit: unit, alarmPlaying: playAlarmIfNeeded(event, seconds: 8))
    }

    func stopAlarm() {
        alarm.stop()
    }

    func refreshNotificationStatus() async {
        let status = await notifications.refreshCriticalStatus()
        criticalAlertsAllowed = status.critical
        timeSensitiveAllowed = status.timeSensitive
        notificationProblem = status.problem
    }

    /// Snooze from the app or from a notification (`eventDate`: when that alert was sent).
    func acknowledge(ruleID: UUID, eventDate: Date? = nil) {
        engine.acknowledge(ruleID: ruleID, at: Date(), eventDate: eventDate)
        alarm.stop()
        saveAlertState(force: true)
    }

    /// Whether an alert is in an episode it already announced, so Snooze means something.
    func isAlertSounding(_ ruleID: UUID) -> Bool {
        engine.isFiring(ruleID)
    }

    @ObservationIgnored private var alertStateSavedAt = Date.distantPast

    /// Saves the alert engine's memory: right away when something changed, otherwise at most
    /// every 5 minutes (so the gap check after a relaunch knows when the last reading was).
    private func saveAlertState(force: Bool) {
        guard !isDemo, !ScreenshotMode.isActive else { return }
        guard force || Date().timeIntervalSince(alertStateSavedAt) > 5 * 60 else { return }
        alertStateSavedAt = Date()
        try? stores.alertState.save(engine.snapshot)
    }

    // MARK: Sensor events

    private func handleSensorEvent(_ event: SensorConnection.Event) {
        switch event {
        case .paired:
            lastError = nil
            if let record = sensor.record {
                notifications.scheduleWarmUpDone(at: record.warmUpEndsAt)
            }
            if settings.dataSource != .libre {
                settings.dataSource = .libre
                settingsChanged()
            } else {
                activateSource()
            }
        case .bluetoothOff:
            if settings.bluetoothAlert {
                notifications.post(title: "Bluetooth is off", body: "Glucose readings have stopped. Turn Bluetooth on to reconnect.")
            }
        case .sensorEnded:
            notifications.post(title: "Sensor ended", body: "Start a new sensor with LibreLink, then pair it in this app.")
        case .scanned:
            lastError = nil
        case .error(let message):
            lastError = message
        case .timelineShifted(let serial, let activatedAt, let interval):
            // The phone clock changed or drifted: re-date this sensor's readings everywhere, so
            // new readings don't sort before old ones (that would stop alerts and updates).
            readings = ReadingPipeline.retimed(readings, sensorSerial: serial, activatedAt: activatedAt)
            engine.shiftTimeline(by: interval)
            saveAlertState(force: true)
            do {
                try stores.archive?.retime(sensorSerial: serial, activatedAt: activatedAt, through: Date())
            } catch {
                lastError = "Couldn't update saved readings: \(error.localizedDescription)"
            }
        }
    }

    // MARK: Settings

    /// Called whenever `settings` changes: saves and applies what changed.
    func settingsChanged() {
        let old = savedSettings
        savedSettings = settings
        do {
            try stores.settings.save(settings)
        } catch {
            lastError = "Couldn't save settings: \(error.localizedDescription)"
        }
        if old.ruleSet != settings.ruleSet {
            engine.ruleSet = settings.ruleSet
        }
        sensor.allowUnverifiedTypes = settings.allowUnverifiedSensorTypes
        sensor.recordAllRawData = settings.recordAllRawData
        if old.dataSource != settings.dataSource || old.demoSpeed != settings.demoSpeed {
            activateSource(resetEngine: true)
        }
        if old.liveActivity && !settings.liveActivity {
            surfaces.endLiveActivity()
        }
    }

    func updateRules(_ change: (inout AlertRuleSet) throws -> Void) {
        var copy = settings.ruleSet
        do {
            try change(&copy)
            settings.ruleSet = copy
            lastError = nil
        } catch {
            lastError = "\(error)"
        }
    }

    func addRule(_ direction: AlertDirection) {
        let existing = settings.ruleSet.rules(for: direction).map(\.thresholdMgdL)
        let threshold: Double
        let sound: SoundStyle
        switch direction {
        case .low:
            threshold = max(AlertRuleSet.thresholdRangeMgdL.lowerBound, (existing.min() ?? 80) - 5)
            sound = .tune(name: "alarm_loud_low")
        case .high:
            threshold = min(AlertRuleSet.thresholdRangeMgdL.upperBound, (existing.max() ?? 180) + 20)
            sound = .tune(name: "alarm_high")
        }
        updateRules {
            try $0.add(AlertRule(name: direction == .low ? "New low" : "New high", direction: direction,
                                 thresholdMgdL: threshold, sound: sound))
        }
    }

    // MARK: Logbook and fingersticks

    func addLogEntry(_ entry: LogEntry) {
        logbook.append(entry)
        logbook.sort { $0.date > $1.date }
        try? stores.logbook.save(logbook)
    }

    func deleteLogEntries(_ ids: Set<UUID>) {
        logbook.removeAll { ids.contains($0.id) }
        try? stores.logbook.save(logbook)
    }

    /// Records a fingerstick. Returns a message describing what happened.
    @discardableResult
    func addFingerstick(mgdL: Double, date: Date, calibrate: Bool) -> String {
        var usedForCalibration = false
        var message = "Fingerstick saved."
        if calibrate {
            if isDemo {
                message = "Saved. Calibration only applies to a real sensor."
            } else if sensor.calibrate(referenceMgdL: mgdL, at: date) {
                usedForCalibration = true
                message = "Calibrated. New readings use this fingerstick."
            } else {
                message = "Saved, but not used for calibration: no sensor value from the last 10 minutes."
            }
        }
        fingersticks.append(FingerstickEntry(date: date, mgdL: mgdL, usedForCalibration: usedForCalibration,
                                             sensorSerial: sensor.record?.serial))
        fingersticks.sort { $0.date > $1.date }
        try? stores.fingersticks.save(fingersticks)
        return message
    }

    func deleteFingersticks(_ ids: Set<UUID>) {
        fingersticks.removeAll { ids.contains($0.id) }
        try? stores.fingersticks.save(fingersticks)
    }

    var accuracy: AccuracyReport {
        AccuracyReport(fingersticks: fingersticks, readings: readings)
    }

    /// Deletes readings, notes, fingersticks and raw captures older than `archiveDays`.
    /// Runs at launch and then once a day while readings arrive.
    func pruneOldData() {
        lastPrune = Date()
        let cutoff = Date().addingTimeInterval(-Self.archiveDays * 86_400)
        try? stores.archive?.prune(olderThan: cutoff)
        if logbook.contains(where: { $0.date < cutoff }) {
            logbook.removeAll { $0.date < cutoff }
            try? stores.logbook.save(logbook)
        }
        if fingersticks.contains(where: { $0.date < cutoff }) {
            fingersticks.removeAll { $0.date < cutoff }
            try? stores.fingersticks.save(fingersticks)
        }
        sensor.deleteSaved(olderThan: cutoff)
        stores.pruneCaptures(olderThan: cutoff)
    }

    // MARK: Live Activity

    /// Starts the Live Activity again, e.g. after it was swiped away from the Lock Screen.
    /// Returns a message to show when it can't.
    func restartLiveActivity() -> String? {
        guard surfaces.liveActivitiesAllowed else {
            return "Live Activities are turned off for this app. Turn them on in iOS Settings > Glucose > Live Activities."
        }
        settings.liveActivity = true
        guard let latest = readings.last else { return "There is no glucose reading to show yet." }
        surfaces.restartLiveActivity(latest: latest, arrow: trendArrow, unit: unit)
        return nil
    }

    // MARK: Lifecycle

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .active:
            let wasInactive = !isActive
            isActive = true
            if wasInactive {
                // Opening the app (or tapping the notification) means the alarm was heard.
                alarm.stop()
                catchUpDemo()
            }
            if wasInactive, settings.biometricLock, isLocked {
                Task { await unlock() }
            }
            if wasInactive, started, !ScreenshotMode.isActive {
                // The user may be back from turning Critical Alerts on in iOS Settings.
                Task { await refreshNotificationStatus() }
            }
            if pausedInBackground {
                pausedInBackground = false
                if !isDemo { sensor.start() }
            } else if !isDemo {
                sensor.appDidBecomeActive()
            }
        case .background:
            isActive = false
            if settings.biometricLock { isLocked = true }
            scheduleDemoAlertsAhead()
            if !settings.runInBackground, started, !isDemo {
                // Saves battery: no Bluetooth while closed, so no alerts and no stale Lock Screen value.
                pausedInBackground = true
                sensor.stop()
                notifications.cancelMissingData()
                surfaces.endLiveActivity()
            }
        default:
            break
        }
    }

    func unlock() async {
        isLocked = !(await BiometricLock.authenticate())
    }

    private func startBatteryMonitoring() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        batteryObserver = NotificationCenter.default.addObserver(
            forName: UIDevice.batteryLevelDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkBattery() }
        }
    }

    private func checkBattery() {
        let level = UIDevice.current.batteryLevel
        let charging = UIDevice.current.batteryState == .charging || UIDevice.current.batteryState == .full
        if charging || level > 0.25 {
            batteryAlerted = false
        } else if level >= 0, level < 0.15, !batteryAlerted, settings.batteryAlert, !isDemo {
            batteryAlerted = true
            notifications.post(title: "Phone battery low",
                               body: "If the phone turns off, glucose alerts stop. Charge it soon.")
        }
    }

    // MARK: Backup

    func makeBackup(password: String) throws -> URL {
        let now = Date()
        let all = isDemo ? [] : ((try? stores.archive?.load(from: now.addingTimeInterval(-Self.archiveDays * 86_400),
                                                             to: now.addingTimeInterval(3600))) ?? [])
        let payload = BackupPayload(createdAt: now, settings: settings, sensor: sensor.record,
                                    logbook: logbook, fingersticks: fingersticks, readings: all)
        return try BackupService.write(payload, password: password)
    }

    /// Restores a backup, merging notes, fingersticks and readings with what's already here.
    func restoreBackup(from url: URL, password: String) throws -> String {
        let payload = try BackupService.read(from: url, password: password)
        var restored = payload.settings
        restored.onboardingDone = true
        settings = restored

        let knownNotes = Set(logbook.map(\.id))
        logbook = (logbook + payload.logbook.filter { !knownNotes.contains($0.id) }).sorted { $0.date > $1.date }
        try? stores.logbook.save(logbook)
        let knownSticks = Set(fingersticks.map(\.id))
        fingersticks = (fingersticks + payload.fingersticks.filter { !knownSticks.contains($0.id) }).sorted { $0.date > $1.date }
        try? stores.fingersticks.save(fingersticks)
        try stores.archive?.append(payload.readings)
        if sensor.record == nil, let record = payload.sensor {
            sensor.restore(record)
        }
        settingsChanged()
        activateSource()
        return "Restored \(payload.readings.count) readings, \(payload.logbook.count) notes and \(payload.fingersticks.count) fingersticks."
    }

    /// Erases readings, logbook, fingersticks, captures and the sensor pairing.
    func deleteAllData() {
        sensor.forget()
        stores.deleteEverything()
        readings = []
        logbook = []
        fingersticks = []
        recentEvents = []
        activateSource(resetEngine: true)
    }
}
