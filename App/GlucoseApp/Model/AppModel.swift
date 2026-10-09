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
    /// Goes up each time the Face ID lock engages: views with sheets close them when it changes.
    private(set) var lockCount = 0
    /// Covers the screen while the app is inactive with the Face ID lock on, so the App Switcher
    /// snapshot shows no glucose data.
    private(set) var privacyCover = false
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
    /// Readings whose save to the archive failed, tried again with the next ones.
    @ObservationIgnored private var pendingArchive: [GlucoseReading] = []
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
        // Locked from the first frame: start() asks for notifications before Face ID.
        self.isLocked = settings.biometricLock
        self.engine = AlertEngine(ruleSet: settings.ruleSet)
        engine.unit = settings.unit
        // Snoozes, repeats and the decision log survive iOS relaunching the app.
        if settings.dataSource == .libre, !ScreenshotMode.isActive, let saved = stores.alertState.load() {
            engine.restore(saved, now: Date())
        }
        // The log has its own file, written in the demo too, so it also survives a change of source.
        if !ScreenshotMode.isActive, let lines = stores.decisionLog.load() {
            engine.restoreLog(lines)
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
        notifications.onTreating = { [weak self] id, sentAt in self?.handleLockScreenAction(.treating, ruleID: id, eventDate: sentAt) }
        // The Live Activity's Snooze and Treating buttons.
        AlertIntentBridge.shared.handler = { [weak self] action, id in self?.handleLockScreenAction(action, ruleID: id) }
        // An alarm cut off by a call or Siri that can't resume: send the alert again with a sound.
        alarm.onResumeFailed = { [weak self] in
            guard let self, let event = self.lastAlarmEvent else { return }
            self.notifications.deliver(event, unit: self.unit, alarmPlaying: false)
        }
        // iOS relaunches the app in the background for Bluetooth events. The Bluetooth manager has
        // to exist from launch, with its restore identifier, not only once the first screen runs
        // start() (which may not happen in the background). With "Run in background" off the
        // connection was stopped when the app left, so iOS doesn't relaunch it for Bluetooth.
        if settings.dataSource == .libre, settings.runInBackground, sensor.record != nil, !ScreenshotMode.isActive {
            sensor.start()
        }
        syncDecisionLog()
    }

    // MARK: Derived state

    var unit: GlucoseUnit { settings.unit }
    var latest: GlucoseReading? { readings.last }
    /// The alert engine's decisions, newest first. Kept as observed state (the engine itself isn't
    /// observed), so an open log screen shows new decisions.
    private(set) var decisionLog: [String] = []

    /// An alert that is sounding now, and when its snooze ends if it's snoozed.
    struct AlertStatus: Equatable {
        var snoozedUntil: Date?
    }

    /// The sounding alerts by id, kept as observed state (the engine itself isn't observed), so
    /// Home shows Snooze, or "Snoozed until …" once tapped, and nothing once the alert is over.
    private(set) var soundingAlerts: [UUID: AlertStatus] = [:]

    private func syncAlertStatus() {
        let now = Date()
        var status: [UUID: AlertStatus] = [:]
        for rule in settings.ruleSet.rules where engine.isFiring(rule.id) {
            status[rule.id] = AlertStatus(snoozedUntil: engine.states[rule.id]?.snoozedUntil.flatMap { $0 > now ? $0 : nil })
        }
        for alert in settings.ruleSet.trendAlerts where engine.isFiring(alert.id) {
            status[alert.id] = AlertStatus(snoozedUntil: engine.trendStates[alert.id]?.snoozedUntil.flatMap { $0 > now ? $0 : nil })
        }
        if status != soundingAlerts { soundingAlerts = status }
    }

    /// Also refreshes the observed alert status: both change with every engine decision.
    private func syncDecisionLog() {
        syncAlertStatus()
        guard engine.log.count != decisionLog.count || engine.log.last != decisionLog.first else { return }
        decisionLog = engine.log.reversed()
        if !ScreenshotMode.isActive { try? stores.decisionLog.save(engine.log) }
    }
    var isDemo: Bool { settings.dataSource == .demo }

    var trendArrow: TrendArrow { trendArrow(at: Date()) }

    /// The arrow as of `now`. Views pass the time from a TimelineView, so the arrow turns into "?"
    /// when readings stop even if nothing else changes.
    func trendArrow(at now: Date) -> TrendArrow {
        guard let latest, now.timeIntervalSince(latest.timestamp) < 15 * 60 || isDemo else { return .unknown }
        return Trend.arrow(forRate: Trend.ratePerMinute(readings(lastHours: 0.5)))
    }

    /// True when the newest value is too old to show as current.
    var isStale: Bool { isStale(at: Date()) }

    func isStale(at now: Date) -> Bool {
        guard let latest else { return true }
        return !isDemo && now.timeIntervalSince(latest.timestamp) > 10 * 60
    }

    /// Missing readings in the last 24 hours, e.g. after the phone was out of range.
    /// "No data right now" isn't included; the stale-value banner covers that.
    var readingGap: DateInterval? { readingGap(at: Date()) }

    func readingGap(at now: Date) -> DateInterval? {
        guard !isDemo, sensor.record != nil else { return nil }
        guard let gap = ReadingPipeline.recentGap(in: readings, now: now, minimumMinutes: 20, lookbackHours: 24),
              gap.end < now.addingTimeInterval(-60) else { return nil }
        return gap
    }

    /// Whether a gap started before the current sensor gave readings (the change between sensors,
    /// or its warm-up): no scan can fill it.
    func isGapBetweenSensors(_ gap: DateInterval) -> Bool {
        guard let record = sensor.record else { return false }
        return gap.start < record.warmUpEndsAt.addingTimeInterval(-60)
    }

    /// The sensor keeps 8 hours of history, so a gap that started within that window can be filled by NFC.
    func canFillWithNFC(_ gap: DateInterval) -> Bool {
        !isGapBetweenSensors(gap) && gap.start > Date().addingTimeInterval(-8 * 3600 + 15 * 60)
    }

    func readings(lastHours hours: Double) -> [GlucoseReading] {
        guard let end = latest?.timestamp else { return [] }
        let start = end.addingTimeInterval(-hours * 3600)
        // Readings are sorted by time: walk back from the newest instead of scanning two weeks.
        var index = readings.endIndex
        while index > readings.startIndex, readings[index - 1].timestamp >= start { index -= 1 }
        return Array(readings[index...])
    }

    func readings(in interval: DateInterval) -> [GlucoseReading] {
        readings.filter { interval.contains($0.timestamp) }
    }

    /// Readings for a report. A period inside the readings held in memory uses those; a longer
    /// one decodes the archive off the main thread (90 days is about 130,000 lines), once: the
    /// part older than memory is kept for an hour and joined with the newest readings.
    func reportReadings(in interval: DateInterval) async -> [GlucoseReading] {
        let inMemory = readings
        let memoryStart = inMemory.first?.timestamp ?? interval.end
        guard !isDemo, interval.start < memoryStart, let archive = stores.archive else { return readings(in: interval) }
        let older: [GlucoseReading]
        if let cache = archiveCache, cache.start <= interval.start, Date().timeIntervalSince(cache.loadedAt) < 3600 {
            older = cache.readings
        } else {
            let start = interval.start
            let loaded = await Self.offMain { (try? archive.load(from: start, to: memoryStart)) ?? [] }
            guard !Task.isCancelled else { return [] }
            archiveCache = (start, Date(), loaded)
            older = loaded
        }
        return older.filter { $0.timestamp >= interval.start && $0.timestamp < memoryStart } + readings(in: interval)
    }

    /// The archive part of the last long report, so switching periods doesn't decode it again.
    @ObservationIgnored private var archiveCache: (start: Date, loadedAt: Date, readings: [GlucoseReading])?

    /// Forgets the cached archive part, after anything rewrote or removed stored readings.
    func invalidateArchiveCache() {
        archiveCache = nil
    }

    /// Runs `work` off the main thread. Cancelling the caller (a view's `.task` going away)
    /// cancels it too, which a plain `Task.detached` would ignore.
    nonisolated static func offMain<T>(_ work: @escaping @Sendable () -> T) async -> T {
        let task = Task.detached(priority: .userInitiated) { work() }
        return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    // MARK: Startup

    func start() async {
        guard !started else { return }
        started = true
        // A background launch (iOS relaunching the app for Bluetooth) must not count as the app
        // being open: that would skip stopping the alarm, Face ID and the status refresh later.
        // (During a normal launch the state can still be .inactive, which counts as open.)
        isActive = UIApplication.shared.applicationState != .background
        // Launched in the background (a notification action) with "Run in background" off: the
        // sensor waits until the app is opened, as it would after leaving the app.
        if !isActive, !settings.runInBackground, settings.dataSource == .libre {
            pausedInBackground = true
            sensor.stop(pausing: true)
        }
        // Reports, backups and captures shared earlier aren't needed any more.
        AppStores.clearExports()
        signatureExpiry = ProvisioningProfile.expirationDate()
        notifications.scheduleSignatureReminders(expiry: signatureExpiry)
        startBatteryMonitoring()
        // The sensor and alerts first: neither waits for Face ID or the notification prompt.
        activateSource()
        pruneOldData()
        if settings.biometricLock {
            isLocked = true
            // In the background Face ID can't be shown; opening the app asks for it.
            if isActive { Task { await unlock() } }
        }
        if !ScreenshotMode.isActive {
            await notifications.requestAuthorization()
            await refreshNotificationStatus()
        }
        rescheduleBedtimeReminder()
        // After iOS relaunched the app (say, for a Lock Screen button), the Live Activity shows
        // the alert state as it is now instead of waiting for the next reading.
        if let latest, Date().timeIntervalSince(latest.timestamp) < 3600 { updateSurfaces() }
    }

    /// Starts the chosen data source. `resetEngine` is for a change of data source: alerts from
    /// the demo and the real sensor must not mix. Pairing again or restoring a backup keeps the
    /// alert engine, so a snooze isn't lost and a low already announced doesn't alarm again as new.
    func activateSource(resetEngine: Bool = false) {
        demoTask?.cancel()
        notifications.cancelDemoAlerts()
        if resetEngine {
            // A fresh alert memory, but the decision log carries on.
            let log = engine.log
            engine = AlertEngine(ruleSet: settings.ruleSet)
            engine.unit = unit
            engine.restoreLog(log)
            engine.note("alert memory reset, source: \(settings.dataSource.title)", at: Date())
            stores.alertState.delete()
            recentEvents = []
            alarm.stop()
            // The widgets and the Live Activity mustn't keep showing the other source's value.
            surfaces.reset()
        } else {
            engine.ruleSet = settings.ruleSet
        }
        syncDecisionLog()
        switch settings.dataSource {
        case .demo:
            sensor.stop()
            notifications.cancelMissingData()
            startDemo()
        case .libre:
            sensor.clearSimulated()
            let now = Date()
            readings = (try? stores.archive?.load(from: now.addingTimeInterval(-Self.memoryDays * 86_400),
                                                  to: now.addingTimeInterval(3600))) ?? []
            // Trend alerts need the last minutes of history, not just the next live readings.
            engine.addHistory(readings(lastHours: 0.5))
            // Paused while closed with "Run in background" off: it starts when the app opens.
            if !pausedInBackground { sensor.start() }
            if let record = sensor.record {
                notifications.scheduleSensorReminders(SensorLifecycle.reminders(expiresAt: record.expiresAt, now: now))
            }
            if resetEngine {
                // Coming from the demo: its "no data" alerts are replaced by the sensor's, and the
                // widgets show the newest real reading (marked old if it is).
                rescheduleMissingDataForSensor()
                if let latest, Date().timeIntervalSince(latest.timestamp) < 3600 { updateSurfaces() }
            }
            checkBattery()
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
        sensor.seedSampleSignal(now: end)
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
        // Two checks a day over the last 12 days, a few percent off the demo curve, for the
        // accuracy screenshots. Every other one has a LibreLink value too.
        for index in 0..<24 {
            let date = ago(Double(index / 2) * 1440 + (index.isMultiple(of: 2) ? 1500 : 2100))
            guard let nearest = readings.min(by: { abs($0.timestamp.timeIntervalSince(date)) < abs($1.timestamp.timeIntervalSince(date)) })
            else { continue }
            let meter = (nearest.mgdL * (1 + 0.1 * sin(Double(index) * 1.7))).rounded()
            let libreLink = index.isMultiple(of: 2) ? (nearest.mgdL * (1 + 0.06 * cos(Double(index)))).rounded() : nil
            fingersticks.append(FingerstickEntry(date: nearest.timestamp, mgdL: meter, usedForCalibration: false,
                                                 libreLinkMgdL: libreLink))
        }
        fingersticks.sort { $0.date > $1.date }
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
        // Merges only the last stretch: re-sorting two weeks of readings every minute costs battery.
        let fresh = ReadingPipeline.append(valid, to: &readings)
        if let newest = readings.last?.timestamp {
            let cutoff = newest.addingTimeInterval(-Self.memoryDays * 86_400)
            if let first = readings.firstIndex(where: { $0.timestamp >= cutoff }), first > 0 {
                readings.removeFirst(first)
            }
        }
        // Every real reading is archived, whatever the current source: pairing while still in demo
        // mode imports 8 hours of history before the source switches to the sensor.
        // Readings that failed to save before go again: they're already in memory, so they would
        // never count as fresh again and would be lost at the next launch.
        let toArchive = pendingArchive + fresh.filter { $0.source != .simulated }
        var archiveFailed = false
        if !toArchive.isEmpty {
            do {
                try stores.archive?.append(toArchive)
                pendingArchive = []
            } catch {
                archiveFailed = true
                pendingArchive = Array(toArchive.suffix(3 * 24 * 60))
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
        // Readings are flowing again: an earlier sensor or scan error no longer applies.
        if !archiveFailed, latest.source != .simulated { lastError = nil }

        // Don't alert on old values that arrive late (backfill after a long gap).
        if latest.source == .simulated || Date().timeIntervalSince(latest.timestamp) < 10 * 60 {
            let before = (engine.states, engine.trendStates)
            let events = engine.process(latest)
            // A demo in the background already has its alerts scheduled (see scheduleDemoAlertsAhead).
            deliver(events, notify: !(demoRunsAhead && !isActive))
            saveAlertState(force: !events.isEmpty || before.0 != engine.states || before.1 != engine.trendStates)
        } else {
            let minutes = Int(Date().timeIntervalSince(latest.timestamp) / 60)
            engine.note("no alert check: the newest reading arrived \(minutes) min late "
                        + "(\(unit.formatReading(mgdL: latest.mgdL, includeSymbol: true)))", at: Date())
            syncDecisionLog()
        }
        // In the background the demo stops when iOS suspends the app, which isn't missing data.
        if !isDemo || (settings.demoSpeed == .realTime && isActive) {
            rescheduleMissingData(lastReading: latest.timestamp)
            notifications.clearDeliveredMissingData()
        }
        updateSurfaces()
        bedtimeCheckpoint(isActive: isActive)
    }

    /// Pushes the newest reading to the widgets and the Live Activity.
    private func updateSurfaces() {
        guard let latest else { return }
        surfaces.update(latest: latest, arrow: trendArrow, recent: readings(lastHours: 3), unit: unit,
                        liveActivityEnabled: settings.liveActivity, isDemo: isDemo, isForeground: isActive,
                        extras: liveActivityExtras)
    }

    /// The Live Activity's alert banner, last hour and last dose and meal.
    var liveActivityExtras: LiveActivityExtras {
        var extras = LiveActivityExtras()
        extras.points = Array(ReadingPipeline.sparkline(readings(lastHours: 1)).map(\.mgdL).suffix(13))
        extras.change15 = AlertMessage.change(in: readings(lastHours: 0.5))
        extras.hidesValue = settings.hideValuesOnLockScreen
        // The most severe threshold rule still sounding, lows first, read from the alert engine
        // (saved across relaunches) rather than the in-memory list of recent alerts. A trend
        // alert has no "since", so it doesn't get the banner.
        let sounding = settings.ruleSet.rules
            .filter { $0.isEnabled && engine.isFiring($0.id) }
            .sorted { $0.direction != $1.direction ? $0.direction == .low : $0.isMoreSevere(than: $1) }
        if let rule = sounding.first, let state = engine.states[rule.id] {
            extras.alert = ActivityAlert(name: rule.name, ruleID: rule.id.uuidString, isLow: rule.direction == .low,
                                         since: state.crossedSince ?? state.firedAt ?? Date(),
                                         snoozedUntil: state.snoozedUntil.flatMap { $0 > Date() ? $0 : nil })
        }
        return extras
    }

    /// The words and 2-hour chart of an alert notification.
    private func alertDetails(for event: AlertEvent) -> NotificationService.AlertDetails {
        let rule = settings.ruleSet.rules.first { $0.id == event.ruleID }
        let since = rule == nil ? nil : engine.states[event.ruleID]?.crossedSince
        if settings.hideValuesOnLockScreen {
            // The Lock Screen, and a paired Watch, learn only that there's an alert.
            return NotificationService.AlertDetails(title: event.ruleName, body: "Open Glucose to see the value.", chartURL: nil)
        }
        return NotificationService.AlertDetails(
            title: AlertMessage.title(for: event, unit: unit, arrow: trendArrow(at: event.date)),
            body: AlertMessage.body(for: event, unit: unit, change15: AlertMessage.change(in: readings(lastHours: 0.5)),
                                    thresholdMgdL: rule?.thresholdMgdL, since: since,
                                    time: { $0.formatted(date: .omitted, time: .shortened) }),
            // With the Face ID lock on, the Lock Screen gets no chart of the last hours.
            chartURL: settings.biometricLock ? nil
                : AlertChartRenderer.render(readings: readings(lastHours: 2), unit: unit, threshold: rule?.thresholdMgdL))
    }

    static let treatingNote = "Treating a low"

    /// Snooze or Treating from a notification or the Live Activity. Treating also logs it, so
    /// the logbook shows when the low was treated.
    func handleLockScreenAction(_ action: AlertIntentAction, ruleID: UUID, eventDate: Date? = nil) {
        // Once per few minutes: Treating tapped on the notification and on the card is one treatment.
        let recentlyLogged = logbook.contains {
            $0.text == Self.treatingNote && Date().timeIntervalSince($0.date) < 10 * 60
        }
        if action == .treating, !recentlyLogged {
            addLogEntry(LogEntry(date: Date(), kind: .meal(carbsGrams: nil), text: Self.treatingNote))
        }
        acknowledge(ruleID: ruleID, eventDate: eventDate)
    }

    /// Replaces the scheduled "No glucose data" notifications, counting from `lastReading`.
    /// Off, or no sensor source: they are only cancelled.
    private func rescheduleMissingData(lastReading: Date) {
        guard settings.missingData.isEnabled else {
            notifications.cancelMissingData()
            return
        }
        let warmUp = isDemo ? nil : sensor.record?.warmUpEndsAt
        notifications.scheduleMissingData(settings.missingData.fireDates(lastReading: lastReading, warmUpEnds: warmUp),
                                          lastReading: lastReading, config: settings.missingData)
    }

    /// The real sensor's missing-data alerts after a change (settings, pairing, a new source):
    /// counted from the newest reading, or from now if there is none or it's from before a pairing.
    private func rescheduleMissingDataForSensor() {
        guard !isDemo, sensor.record != nil, settings.runInBackground || isActive else {
            notifications.cancelMissingData()
            return
        }
        rescheduleMissingData(lastReading: max(readings.last?.timestamp ?? Date(), sensor.record?.pairedAt ?? .distantPast))
    }

    @ObservationIgnored private var lastAlarmEvent: AlertEvent?

    private func deliver(_ events: [AlertEvent], notify: Bool = true) {
        guard !events.isEmpty else { return }
        if notify {
            // One alarm per reading, the first event first (threshold rules come before trend
            // alerts): a second alarm would cut off the first, usually more severe, one.
            var alarmStarted = false
            for event in events {
                var alarmHeard = false
                if !alarmStarted, playAlarmIfNeeded(event) {
                    alarmStarted = true
                    lastAlarmEvent = event
                    // The notification only goes quiet if the app's alarm is clearly audible.
                    alarmHeard = AlarmPlayer.isClearlyAudible
                }
                notifications.deliver(event, unit: unit, alarmPlaying: alarmHeard, details: alertDetails(for: event))
                if settings.speakValues, isActive, !alarmStarted {
                    voice.announce(event, unit: unit)
                }
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
        syncDecisionLog()
    }

    /// A Critical alert plays from the app while iOS won't let its notification through Silent and Focus.
    private func playAlarmIfNeeded(_ event: AlertEvent, seconds: Double = 30) -> Bool {
        guard event.isCritical, !notifications.criticalAllowed else { return false }
        // A silent rule, or an imported tune missing on this phone, plays the bundled alarm.
        let fallback = SoundCatalog.alarm(for: event.direction)
        let style = event.sound == .silent ? fallback : SoundCatalog.playable(event.sound, fallback: fallback)
        if alarm.play(style, seconds: seconds) { return true }
        return style != fallback && alarm.play(fallback, seconds: seconds)
    }

    /// Sends a rule's alert right away, exactly as it would sound, without logging it.
    func sendTestAlert(for rule: AlertRule) {
        let event = AlertEvent(ruleID: rule.id, ruleName: "Test: \(rule.name)", direction: rule.direction,
                               valueMgdL: rule.thresholdMgdL, date: Date(), sound: rule.sound,
                               isCritical: rule.isCritical, criticalVolume: rule.criticalVolume, kind: .initial)
        sendTest(event)
    }

    /// Sends a trend alert ("Low soon", "Falling fast", "Rising fast") right away, as it would sound.
    func sendTestAlert(for alert: TrendAlert) {
        let value: Double
        if case .predictiveLow(let threshold, _) = alert.kind { value = threshold + 15 } else { value = 120 }
        let event = AlertEvent(ruleID: alert.id, ruleName: "Test: \(alert.name)", direction: alert.kind.direction,
                               valueMgdL: value, date: Date(), sound: alert.sound,
                               isCritical: alert.isCritical, criticalVolume: 1, kind: .initial)
        sendTest(event)
    }

    /// Sends the "No glucose data" alert right away, as it would sound.
    func sendTestMissingDataAlert() {
        notifications.post(title: "Test: No glucose data",
                           body: MissingDataAlert.message(firingAt: Date(), lastReading: Date().addingTimeInterval(-Double(settings.missingData.minutes) * 60)),
                           sound: SoundCatalog.playable(settings.missingData.sound, fallback: .tune(name: "chime")))
    }

    /// Test alerts play the alarm for 8 seconds; real ones for 30.
    private func sendTest(_ event: AlertEvent) {
        let alarmPlaying = playAlarmIfNeeded(event, seconds: 8)
        notifications.deliver(event, unit: unit, alarmPlaying: alarmPlaying && AlarmPlayer.isClearlyAudible, isTest: true)
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
        // A demo running ahead in the background: bring it up to now first (its alerts were only
        // scheduled), snooze, then schedule the rest again so the snoozed reminders don't come.
        let demoAhead = demoRunsAhead && !isActive
        if demoAhead { catchUpDemo() }
        engine.acknowledge(ruleID: ruleID, at: Date(), eventDate: eventDate)
        alarm.stop()
        saveAlertState(force: true)
        if demoAhead { scheduleDemoAlertsAhead() }
        // The Live Activity drops its Snooze button.
        updateSurfaces()
    }

    /// Whether an alert is in an episode it already announced, so Snooze means something.
    func isAlertSounding(_ ruleID: UUID) -> Bool {
        engine.isFiring(ruleID)
    }

    @ObservationIgnored private var alertStateSavedAt = Date.distantPast

    /// Saves the alert engine's memory: right away when something changed, otherwise at most
    /// every 5 minutes (so the gap check after a relaunch knows when the last reading was).
    private func saveAlertState(force: Bool) {
        syncDecisionLog()
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
            // Old "no data" alerts (from the demo or the previous sensor) must not fire during the
            // new sensor's warm-up.
            rescheduleMissingDataForSensor()
        case .bluetoothOff:
            if settings.bluetoothAlert {
                notifications.post(title: "Bluetooth is off", body: "Glucose readings have stopped. Turn Bluetooth on to reconnect.")
            }
        case .sensorEnded:
            notifications.cancelMissingData()
            // The scheduled "Sensor ended" reminder says the same: show one notification, not two.
            notifications.cancelSensorReminders()
            notifications.post(title: "Sensor ended", body: "Start a new sensor with LibreLink, then pair it in this app.")
        case .forgotten:
            notifications.cancelMissingData()
            notifications.cancelSensorReminders()
            surfaces.endLiveActivity()
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
                archiveCache = nil
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
        engine.unit = settings.unit
        // The queued "No glucose data" alerts follow the new settings right away, also while no
        // reading arrives to reschedule them (which is exactly when they fire).
        if old.missingData != settings.missingData, settings.dataSource == old.dataSource {
            rescheduleMissingDataForSensor()
        }
        if settings.batteryAlert, !old.batteryAlert {
            checkBattery()
        }
        sensor.allowUnverifiedTypes = settings.allowUnverifiedSensorTypes
        sensor.recordAllRawData = settings.recordAllRawData
        if old.bedtimeCheck != settings.bedtimeCheck || old.bedtimeMinutes != settings.bedtimeMinutes
            || old.dataSource != settings.dataSource {
            rescheduleBedtimeReminder()
        }
        if old.dataSource != settings.dataSource || old.demoSpeed != settings.demoSpeed {
            activateSource(resetEngine: true)
        }
        if old.liveActivity && !settings.liveActivity {
            surfaces.endLiveActivity()
        }
        if old.hideValuesOnLockScreen != settings.hideValuesOnLockScreen {
            updateSurfaces()
        }
    }

    func updateRules(_ change: (inout AlertRuleSet) throws -> Void) {
        var copy = settings.ruleSet
        do {
            try change(&copy)
            settings.ruleSet = copy
            lastError = nil
        } catch let error as AlertRuleSet.RuleSetError {
            switch error {
            case .tooManyRules(let direction):
                lastError = "You can have up to \(AlertRuleSet.maxRulesPerDirection) \(direction == .low ? "low" : "high") alerts."
            case .thresholdOutOfRange:
                let range = AlertRuleSet.thresholdRangeMgdL
                lastError = "Alert thresholds must be between \(unit.format(mgdL: range.lowerBound)) and \(unit.format(mgdL: range.upperBound, includeSymbol: true))."
            case .ruleNotFound:
                lastError = "That alert no longer exists."
            }
        } catch {
            lastError = error.localizedDescription
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
    func addFingerstick(mgdL: Double, date: Date, calibrate: Bool, libreLinkMgdL: Double? = nil) -> String {
        var pointID: UUID?
        var message = "Fingerstick saved."
        // What the app showed for that moment (the newest reading at or before it), kept with the
        // check: a calibration, this one included, rewrites the readings around it. Taken before
        // calibrating, so a stick used to calibrate is scored against what was shown before it.
        let shown: Double? = readings.last(where: {
            $0.timestamp <= date && date.timeIntervalSince($0.timestamp) <= 5 * 60
        })?.mgdL
        if calibrate {
            message = calibrateSensor(mgdL: mgdL, date: date, pointID: &pointID)
        }
        fingersticks.append(FingerstickEntry(date: date, mgdL: mgdL, usedForCalibration: pointID != nil,
                                             sensorSerial: sensor.record?.serial, calibrationPointID: pointID,
                                             libreLinkMgdL: libreLinkMgdL, offeredForCalibration: calibrate,
                                             appMgdL: shown))
        fingersticks.sort { $0.date > $1.date }
        try? stores.fingersticks.save(fingersticks)
        return message
    }

    /// Offers a fingerstick to the sensor's calibration and says what happened.
    private func calibrateSensor(mgdL: Double, date: Date, pointID: inout UUID?) -> String {
        guard !isDemo else { return "Saved. Calibration only applies to a real sensor." }
        guard let record = sensor.record else { return "Saved, but not used for calibration: no sensor is paired." }
        if record.ageMinutes(at: date) < LibreSensorRecord.warmUpMinutes {
            let ready = record.warmUpEndsAt.formatted(date: .omitted, time: .shortened)
            return "Saved, but not used for calibration: the sensor is still warming up. Calibrate after \(ready)."
        }
        // The raw value at the fingerstick's time, not the latest one: glucose may have moved since.
        let nearby = readings.filter {
            $0.sensorSerial == record.serial && $0.raw != nil && abs($0.timestamp.timeIntervalSince(date)) <= 3 * 60
        }
        guard let closest = nearby.min(by: { abs($0.timestamp.timeIntervalSince(date)) < abs($1.timestamp.timeIntervalSince(date)) }),
              let raw = closest.raw else {
            return "Saved, but not used for calibration: no sensor value within 3 minutes of that time."
        }
        switch sensor.calibrate(referenceMgdL: mgdL, raw: raw, at: date) {
        case .applied(let id)?:
            pointID = id
            recalibrateRecent()
            return "Calibrated. Values from the last 30 minutes and new readings use this fingerstick."
        case .warmingUp?:
            return "Saved, but not used for calibration: the sensor is still warming up."
        case .needsConfirmation(let sensorMgdL)?:
            return "Saved, but not used for calibration yet: it's far from the sensor's \(unit.format(mgdL: sensorMgdL, includeSymbol: true)). Wash and dry your hands and test again. If a second fingerstick within 30 minutes agrees, it will be used."
        case .tooOld?:
            return "Saved, but not used for calibration: it's more than 4 days before the newest calibration."
        case nil:
            return "Saved, but not used for calibration: no sensor is paired."
        }
    }

    /// After the calibration changed, recomputes the last 30 minutes with it, so old and new values
    /// don't form a step that reads as a fast rise or fall (false arrows and "Low soon" alerts).
    private func recalibrateRecent() {
        guard let record = sensor.record else { return }
        let since = Date().addingTimeInterval(-30 * 60)
        readings = ReadingPipeline.recalibrated(readings, sensorSerial: record.serial, since: since,
                                                calibration: record.calibration)
        engine.recalibrate(sensorSerial: record.serial, calibration: record.calibration)
        saveAlertState(force: true)
        do {
            try stores.archive?.recalibrate(sensorSerial: record.serial, since: since, calibration: record.calibration)
            archiveCache = nil
        } catch {
            lastError = "Couldn't update saved readings: \(error.localizedDescription)"
        }
        updateSurfaces()
    }

    /// Deletes fingersticks. A calibration fingerstick also leaves the sensor's calibration.
    func deleteFingersticks(_ ids: Set<UUID>) {
        let removed = fingersticks.filter { ids.contains($0.id) }
        fingersticks.removeAll { ids.contains($0.id) }
        try? stores.fingersticks.save(fingersticks)
        var calibrationChanged = false
        for stick in removed where stick.usedForCalibration {
            if sensor.removeCalibration(pointID: stick.calibrationPointID, date: stick.date, mgdL: stick.mgdL) {
                calibrationChanged = true
            }
        }
        if calibrationChanged { recalibrateRecent() }
    }

    /// Empty in the demo: comparing real fingersticks with a made-up curve would show a
    /// meaningless MARD.
    var accuracy: AccuracyReport {
        isDemo && !ScreenshotMode.isActive ? AccuracyReport(pairs: []) : AccuracyReport(fingersticks: fingersticks, readings: readings)
    }

    /// The accuracy report over every fingerstick on file (91 days), not just the 14 days of
    /// readings in memory. Older readings come from the archive, off the main thread.
    func fullAccuracyReport() async -> AccuracyReport {
        guard !isDemo || ScreenshotMode.isActive else { return AccuracyReport(pairs: []) }
        let sticks = fingersticks.filter(AccuracyReport.isScored)
        let inMemory = readings
        guard let oldest = sticks.map(\.date).min() else { return AccuracyReport(pairs: []) }
        let archive = stores.archive
        let needsArchive = oldest < (inMemory.first?.timestamp ?? .distantFuture)
        return await Task.detached(priority: .userInitiated) {
            var all = inMemory
            if needsArchive, let archive {
                let first = inMemory.first?.timestamp ?? Date()
                let older = (try? archive.load(from: oldest.addingTimeInterval(-20 * 60), to: first)) ?? []
                all = older.filter { $0.timestamp < first } + inMemory
            }
            return AccuracyReport(fingersticks: sticks, readings: all)
        }.value
    }

    /// The sensor whose wear the Sensor screen shows.
    struct WearContext: Equatable {
        var serial: String
        var activatedAt: Date
        var lifetimeDays: Int
        /// The sensor minute at `activatedAt`: 0, except for the demo's endless sensor.
        var firstMinute: Int
        /// The exact end, as the Status section shows it (the strip uses whole days).
        var expiresAt: Date
        func day(at date: Date) -> Int { Int(date.timeIntervalSince(activatedAt) / 86_400) + 1 }
    }

    var wearContext: WearContext? {
        if isDemo {
            // The demo sensor has run for weeks: show it as if it were on day 9 of 15.
            guard let latest = readings.last else { return nil }
            let first = max(0, latest.minuteIndex - 8 * 1440 - 600)
            return WearContext(serial: latest.sensorSerial,
                               activatedAt: latest.timestamp.addingTimeInterval(-Double(latest.minuteIndex - first) * 60),
                               lifetimeDays: 15, firstMinute: first,
                               expiresAt: latest.timestamp.addingTimeInterval(-Double(latest.minuteIndex - first) * 60 + 15 * 86_400))
        }
        guard let record = sensor.record else { return nil }
        return WearContext(serial: record.serial, activatedAt: record.activatedAt,
                           lifetimeDays: Int((Double(record.maxLifeMinutes) / 1440).rounded(.up)), firstMinute: 0,
                           expiresAt: record.expiresAt)
    }

    /// Coverage, calibrations and accuracy for each day of the current sensor's wear. Days older
    /// than the readings in memory come from the archive, off the main thread.
    func wearDays() async -> [SensorWearDay] {
        guard let context = wearContext else { return [] }
        let inMemory = readings
        let sticks = fingersticks.filter { $0.date >= context.activatedAt }
        // Accuracy per day comes from this sensor's checks only, so nothing older than the sensor
        // is loaded (not the whole 91-day archive).
        let scoresChecks = !isDemo || ScreenshotMode.isActive
        let archive = isDemo ? nil : stores.archive
        let needsArchive = context.activatedAt < (inMemory.first?.timestamp ?? .distantFuture)
        return await Task.detached(priority: .userInitiated) {
            var all = inMemory
            if needsArchive, let archive {
                let first = inMemory.first?.timestamp ?? Date()
                let older = (try? archive.load(from: context.activatedAt, to: first)) ?? []
                all = older.filter { $0.timestamp < first } + inMemory
            }
            let accuracy = scoresChecks ? AccuracyReport(fingersticks: sticks, readings: all) : AccuracyReport(pairs: [])
            return SensorWear.days(readings: all, sensorSerial: context.serial, activatedAt: context.activatedAt,
                                   lifetimeDays: context.lifetimeDays, fingersticks: sticks, accuracy: accuracy,
                                   now: max(Date(), inMemory.last?.timestamp ?? Date()), firstMinute: context.firstMinute)
        }.value
    }

    /// Deletes readings, notes, fingersticks and raw captures older than `archiveDays`.
    /// Runs at launch and then once a day while readings arrive.
    func pruneOldData() {
        lastPrune = Date()
        let cutoff = Date().addingTimeInterval(-Self.archiveDays * 86_400)
        try? stores.archive?.prune(olderThan: cutoff)
        archiveCache = nil
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
        surfaces.restartLiveActivity(latest: latest, arrow: trendArrow, unit: unit, isDemo: isDemo, extras: liveActivityExtras)
        return nil
    }

    // MARK: Lifecycle

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .active:
            privacyCover = false
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
            if wasInactive, started, let latest, !GlucoseShared.isStale(timestamp: latest.timestamp, at: Date()) || isDemo {
                // A fresh Live Activity before iOS's 8-hour limit ends this one overnight.
                surfaces.renewLiveActivityIfNeeded(latest: latest, arrow: trendArrow, unit: unit, isDemo: isDemo,
                                                   enabled: settings.liveActivity, extras: liveActivityExtras)
            }
        case .background:
            isActive = false
            AppStores.clearExports(olderThan: 10 * 60)
            if settings.biometricLock {
                isLocked = true
                // The lock covers the app's screens, but a sheet would stay usable on top of it.
                // The app's own sheets close through their state (see `lockCount`), so the same
                // button opens them again later; anything else (a share sheet) is dismissed here.
                lockCount += 1
                dismissPresentedSheets()
            }
            scheduleDemoAlertsAhead()
            if !settings.runInBackground, started, !isDemo {
                // Saves battery: no Bluetooth while closed, so no alerts and no stale Lock Screen value.
                pausedInBackground = true
                sensor.stop(pausing: true)
                notifications.cancelMissingData()
                surfaces.endLiveActivity()
            } else {
                sensor.saveSignal(force: true)
            }
        case .inactive:
            // iOS takes the App Switcher snapshot right after this, often before the lock is
            // drawn on .background: with the Face ID lock on, cover the screen already.
            if settings.biometricLock { privacyCover = true }
        @unknown default:
            break
        }
    }

    func unlock() async {
        isLocked = !(await BiometricLock.authenticate())
    }

    private func dismissPresentedSheets() {
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            for window in scene.windows where window.rootViewController?.presentedViewController != nil {
                window.rootViewController?.dismiss(animated: false)
            }
        }
    }

    private func startBatteryMonitoring() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        batteryObserver = NotificationCenter.default.addObserver(
            forName: UIDevice.batteryLevelDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkBattery() }
        }
        // A phone already under 15% at launch would otherwise wait for the next level change.
        checkBattery()
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

    /// Writes an encrypted backup. Loading months of readings and 200,000 key-derivation rounds
    /// take seconds, so they run off the main thread. The archive only holds real readings, so
    /// a backup made in the demo still has the whole history.
    func makeBackup(password: String) async throws -> URL {
        let now = Date()
        let archive = stores.archive
        let start = now.addingTimeInterval(-Self.archiveDays * 86_400)
        let end = now.addingTimeInterval(3600)
        let payload = BackupPayload(createdAt: now, settings: settings, sensor: sensor.record,
                                    logbook: logbook, fingersticks: fingersticks, readings: [])
        return try await Task.detached(priority: .userInitiated) {
            var full = payload
            full.readings = (try? archive?.load(from: start, to: end)) ?? []
            return try BackupService.write(full, password: password)
        }.value
    }

    /// Restores a backup, merging notes, fingersticks and readings with what's already here.
    func restoreBackup(from url: URL, password: String) async throws -> String {
        let archive = stores.archive
        // Decrypting, finding which readings are already here and writing the new ones (about
        // 130,000 for 3 months) all run off the main thread. Nothing else changes until the
        // readings are safely stored, so a failure leaves the phone as it was.
        let (payload, added) = try await Task.detached(priority: .userInitiated) { () -> (BackupPayload, Int) in
            let payload = try BackupService.read(from: url, password: password)
            var newReadings = payload.readings
            if let archive, let first = payload.readings.map(\.timestamp).min(),
               let last = payload.readings.map(\.timestamp).max() {
                let known = Set(((try? archive.load(from: first, to: last.addingTimeInterval(1))) ?? []).map(\.id))
                newReadings = payload.readings.filter { !known.contains($0.id) }
            }
            // Only readings not already on file: restoring twice mustn't grow the day files.
            try archive?.append(newReadings)
            return (payload, newReadings.count)
        }.value
        archiveCache = nil

        var restored = payload.settings
        restored.onboardingDone = true
        // The phone keeps its data source: a backup made in the demo mustn't switch a live sensor
        // to simulated values.
        restored.dataSource = settings.dataSource
        restored.demoSpeed = settings.demoSpeed
        settings = restored

        let knownNotes = Set(logbook.map(\.id))
        let newNotes = payload.logbook.filter { !knownNotes.contains($0.id) }
        logbook = (logbook + newNotes).sorted { $0.date > $1.date }
        try? stores.logbook.save(logbook)
        let knownSticks = Set(fingersticks.map(\.id))
        let newSticks = payload.fingersticks.filter { !knownSticks.contains($0.id) }
        fingersticks = (fingersticks + newSticks).sorted { $0.date > $1.date }
        try? stores.fingersticks.save(fingersticks)
        if sensor.record == nil, let record = payload.sensor {
            sensor.restore(record)
        }
        settingsChanged()
        activateSource()
        func count(_ n: Int, _ thing: String) -> String { "\(n) \(thing)\(n == 1 ? "" : "s")" }
        return "Added \(count(added, "reading")), \(count(newNotes.count, "note")) and \(count(newSticks.count, "fingerstick"))"
            + (added < payload.readings.count || newNotes.count < payload.logbook.count || newSticks.count < payload.fingersticks.count
               ? ". The rest of the backup was already on this phone." : ".")
    }

    /// Erases readings, logbook, fingersticks, captures, exported files, the decision log and the
    /// sensor pairing.
    func deleteAllData() {
        sensor.forget()
        sensor.clearCaptures()
        sensor.resetSignalStats()
        stores.deleteEverything()
        archiveCache = nil
        engine.restoreLog([])
        readings = []
        logbook = []
        fingersticks = []
        recentEvents = []
        // Glucose values on the Lock Screen and in Notification Center go too; only the warnings
        // about the app build expiring come back.
        notifications.removeAll()
        notifications.scheduleSignatureReminders(expiry: signatureExpiry)
        rescheduleBedtimeReminder()
        activateSource(resetEngine: true)
    }
}
