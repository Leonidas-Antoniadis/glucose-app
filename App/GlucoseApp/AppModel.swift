import Foundation
import Observation
import GlucoseCore

enum DemoSpeed: String, CaseIterable, Identifiable {
    case realTime = "Real time"
    case fast = "60x"

    var id: String { rawValue }

    var interval: Duration {
        switch self {
        case .realTime: return .seconds(60)
        case .fast: return .seconds(1)
        }
    }
}

/// App state. For now readings come from `SimulatedSensor`; phase 1 replaces it with the
/// NFC + Bluetooth sensor link, and everything downstream stays the same.
@MainActor
@Observable
final class AppModel {
    private(set) var readings: [GlucoseReading] = []
    private(set) var ruleSet: AlertRuleSet = .basic()
    private(set) var recentEvents: [AlertEvent] = []
    var unit: GlucoseUnit = .mgdL
    var missingData = MissingDataAlert()
    var demoSpeed: DemoSpeed = .realTime
    var lastError: String?

    /// Keep 14 days of 1-minute readings in memory (enough for reports).
    static let maxReadings = 14 * 24 * 60

    @ObservationIgnored private var engine: AlertEngine
    @ObservationIgnored private var simulationTask: Task<Void, Never>?
    @ObservationIgnored private var nextMinute = 0
    @ObservationIgnored private var started = false
    @ObservationIgnored private let sensor: SimulatedSensor
    @ObservationIgnored private let store = LocalStore()
    @ObservationIgnored private let notifications = NotificationService()

    init() {
        // Simulated sensor started two days ago, aligned to a whole minute.
        let now = Date()
        let start = Date(timeIntervalSince1970: (now.timeIntervalSince1970 / 60).rounded(.down) * 60 - 2 * 86_400)
        sensor = SimulatedSensor(startedAt: start)
        engine = AlertEngine(ruleSet: .basic())

        if let settings = store.loadSettings() {
            unit = settings.unit
            ruleSet = settings.ruleSet
            missingData = settings.missingData
            engine.ruleSet = settings.ruleSet
        }
    }

    var latest: GlucoseReading? { readings.last }

    var sensorStartedAt: Date { sensor.startedAt }

    var decisionLog: [String] { engine.log.reversed() }

    func readings(lastHours hours: Double) -> [GlucoseReading] {
        guard let end = latest?.timestamp else { return [] }
        let start = end.addingTimeInterval(-hours * 3600)
        return readings.filter { $0.timestamp >= start }
    }

    func start() async {
        guard !started else { return }
        started = true
        await notifications.requestAuthorization()

        // Fill a day of history so charts and reports have something to show.
        nextMinute = Int(Date().timeIntervalSince(sensor.startedAt) / 60)
        readings = sensor.readings(minutes: max(0, nextMinute - 1440)..<nextMinute)
        startSimulation()
    }

    func startSimulation() {
        simulationTask?.cancel()
        let speed = demoSpeed
        simulationTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: speed.interval)
                guard let self, !Task.isCancelled else { return }
                self.ingest(self.sensor.reading(atMinute: self.nextMinute))
                self.nextMinute += 1
            }
        }
    }

    func ingest(_ reading: GlucoseReading) {
        if let last = readings.last, last.timestamp < reading.timestamp {
            readings.append(reading)
        } else {
            readings = ReadingPipeline.merge(readings, with: [reading])
        }
        if readings.count > Self.maxReadings {
            readings.removeFirst(readings.count - Self.maxReadings)
        }

        let events = engine.process(reading)
        for event in events {
            notifications.deliver(event, unit: unit)
        }
        recentEvents.insert(contentsOf: events.reversed(), at: 0)
        if recentEvents.count > 50 {
            recentEvents.removeLast(recentEvents.count - 50)
        }

        // Fast demo time runs ahead of the wall clock, so only real time drives missing-data alerts.
        if demoSpeed == .realTime {
            notifications.scheduleMissingData(
                missingData.fireDates(lastReading: reading.timestamp,
                                      warmUpEnds: SensorLifecycle.warmUpEnds(startedAt: sensor.startedAt)),
                config: missingData
            )
        }
    }

    // MARK: Rules

    func acknowledge(_ event: AlertEvent) {
        engine.acknowledge(ruleID: event.ruleID, at: Date())
    }

    func update(_ rule: AlertRule) {
        perform { try $0.update(rule) }
    }

    func addRule(_ direction: AlertDirection) {
        let existing = ruleSet.rules(for: direction).map(\.thresholdMgdL)
        let threshold: Double
        switch direction {
        case .low: threshold = max(AlertRuleSet.thresholdRangeMgdL.lowerBound, (existing.min() ?? 80) - 5)
        case .high: threshold = min(AlertRuleSet.thresholdRangeMgdL.upperBound, (existing.max() ?? 180) + 20)
        }
        perform {
            try $0.add(AlertRule(name: direction == .low ? "New low" : "New high", direction: direction,
                                 thresholdMgdL: threshold, sound: .tune(name: "chime")))
        }
    }

    func removeRule(id: UUID) {
        perform { $0.remove(id: id) }
    }

    func duplicateRule(id: UUID) {
        perform { try $0.duplicate(id: id) }
    }

    func applyPreset(_ preset: AlertRuleSet) {
        perform { $0 = preset }
    }

    private func perform(_ change: (inout AlertRuleSet) throws -> Void) {
        var copy = ruleSet
        do {
            try change(&copy)
            ruleSet = copy
            engine.ruleSet = copy
            lastError = nil
            saveSettings()
        } catch {
            lastError = "\(error)"
        }
    }

    // MARK: Persistence

    func saveSettings() {
        do {
            try store.saveSettings(AppSettings(unit: unit, ruleSet: ruleSet, missingData: missingData))
        } catch {
            lastError = "Couldn't save settings: \(error.localizedDescription)"
        }
    }
}
