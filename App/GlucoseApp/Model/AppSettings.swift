import Foundation
import GlucoseCore

enum DataSource: String, Codable, CaseIterable, Identifiable {
    case demo
    case libre

    var id: String { rawValue }

    var title: String {
        switch self {
        case .demo: return "Demo sensor"
        case .libre: return "Libre sensor"
        }
    }
}

enum DemoSpeed: String, Codable, CaseIterable, Identifiable {
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

/// Everything the user can configure. Saved as JSON; fields added later decode with defaults.
struct AppSettings: Codable, Hashable {
    var unit: GlucoseUnit = .mgdL
    var ruleSet: AlertRuleSet = .basic()
    var missingData = MissingDataAlert(sound: .voice(clip: "no_data"))
    var dataSource: DataSource = .demo
    var demoSpeed: DemoSpeed = .realTime
    var onboardingDone = false
    var biometricLock = false
    /// Speak the value aloud with alerts while the app is open.
    var speakValues = false
    var liveActivity = true
    var batteryAlert = true
    var bluetoothAlert = true
    /// Lets the app try the Libre 2 EU protocol on sensors it doesn't recognize.
    var allowUnverifiedSensorTypes = false
    /// Write every packet to the capture log (normally only packets you save are kept).
    var recordAllRawData = false
    /// Keep the sensor connection (and alerts) running while the app is closed. Off saves battery.
    var runInBackground = true
    /// Check in the evening that nothing will keep an alarm from sounding overnight.
    var bedtimeCheck = true
    /// Bedtime, in minutes after midnight. The check shows from an hour before.
    var bedtimeMinutes = 22 * 60

    init() {}

    private enum CodingKeys: String, CodingKey {
        case unit, ruleSet, missingData, dataSource, demoSpeed, onboardingDone, biometricLock
        case speakValues, liveActivity, batteryAlert, bluetoothAlert, allowUnverifiedSensorTypes, recordAllRawData, runInBackground
        case bedtimeCheck, bedtimeMinutes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        unit = try c.decodeIfPresent(GlucoseUnit.self, forKey: .unit) ?? d.unit
        ruleSet = try c.decodeIfPresent(AlertRuleSet.self, forKey: .ruleSet) ?? d.ruleSet
        missingData = try c.decodeIfPresent(MissingDataAlert.self, forKey: .missingData) ?? d.missingData
        dataSource = try c.decodeIfPresent(DataSource.self, forKey: .dataSource) ?? d.dataSource
        demoSpeed = try c.decodeIfPresent(DemoSpeed.self, forKey: .demoSpeed) ?? d.demoSpeed
        onboardingDone = try c.decodeIfPresent(Bool.self, forKey: .onboardingDone) ?? d.onboardingDone
        biometricLock = try c.decodeIfPresent(Bool.self, forKey: .biometricLock) ?? d.biometricLock
        speakValues = try c.decodeIfPresent(Bool.self, forKey: .speakValues) ?? d.speakValues
        liveActivity = try c.decodeIfPresent(Bool.self, forKey: .liveActivity) ?? d.liveActivity
        batteryAlert = try c.decodeIfPresent(Bool.self, forKey: .batteryAlert) ?? d.batteryAlert
        bluetoothAlert = try c.decodeIfPresent(Bool.self, forKey: .bluetoothAlert) ?? d.bluetoothAlert
        allowUnverifiedSensorTypes = try c.decodeIfPresent(Bool.self, forKey: .allowUnverifiedSensorTypes) ?? d.allowUnverifiedSensorTypes
        recordAllRawData = try c.decodeIfPresent(Bool.self, forKey: .recordAllRawData) ?? d.recordAllRawData
        runInBackground = try c.decodeIfPresent(Bool.self, forKey: .runInBackground) ?? d.runInBackground
        bedtimeCheck = try c.decodeIfPresent(Bool.self, forKey: .bedtimeCheck) ?? d.bedtimeCheck
        bedtimeMinutes = try c.decodeIfPresent(Int.self, forKey: .bedtimeMinutes) ?? d.bedtimeMinutes
    }
}
