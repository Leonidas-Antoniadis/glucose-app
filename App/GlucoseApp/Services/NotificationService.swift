import Foundation
import UserNotifications
import GlucoseCore

/// Local notifications only. Nothing leaves the phone.
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    static let alertCategory = "GLUCOSE_ALERT"
    static let snoozeAction = "SNOOZE"
    private static let missingDataPrefix = "missing-data-"
    private static let sensorPrefix = "sensor-reminder-"
    private static let signaturePrefix = "signature-"

    /// Called when the user taps Snooze on an alert notification.
    var onSnooze: (@MainActor (UUID) -> Void)?
    /// True once Apple's Critical Alerts entitlement is granted and the user allowed it.
    private(set) var criticalAllowed = false

    override init() {
        super.init()
        center.delegate = self
        let snooze = UNNotificationAction(identifier: Self.snoozeAction, title: "Snooze", options: [])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.alertCategory, actions: [snooze], intentIdentifiers: [], options: []),
        ])
    }

    func requestAuthorization() async {
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
        // Only takes effect once Apple grants the Critical Alerts entitlement; harmless otherwise.
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge, .criticalAlert])
    }

    struct Status {
        /// Apple's Critical Alerts entitlement is granted and the user allowed it.
        var critical: Bool
        /// Time Sensitive notifications are on, so alerts show during Focus.
        var timeSensitive: Bool
        /// Why alerts can't be seen or heard, if they can't.
        var problem: String?
    }

    /// Re-reads the notification switches, which the user can change in iOS Settings at any time.
    @discardableResult
    func refreshCriticalStatus() async -> Status {
        let settings = await center.notificationSettings()
        criticalAllowed = settings.criticalAlertSetting == .enabled
        let problem: String?
        switch settings.authorizationStatus {
        case .denied, .notDetermined:
            problem = "Notifications are off for this app, so alerts can't show or sound."
        default:
            problem = settings.soundSetting == .disabled
                ? "Notification sounds are off for this app, so alerts are silent."
                : nil
        }
        return Status(critical: criticalAllowed, timeSensitive: settings.timeSensitiveSetting == .enabled, problem: problem)
    }

    /// `alarmPlaying`: the app is already playing the sound itself, so the notification stays quiet.
    func deliver(_ event: AlertEvent, unit: GlucoseUnit, alarmPlaying: Bool = false) {
        let content = UNMutableNotificationContent()
        content.title = event.ruleName
        let value = unit.format(mgdL: event.valueMgdL, includeSymbol: true)
        switch event.kind {
        case .initial: content.body = "Glucose \(value)"
        case .reminder(let count): content.body = "Still \(value) (reminder \(count))"
        case .afterSnooze: content.body = "Still \(value) after snooze"
        }
        content.categoryIdentifier = Self.alertCategory
        content.userInfo = ["ruleID": event.ruleID.uuidString]
        content.threadIdentifier = event.direction.rawValue
        let critical = event.isCritical && criticalAllowed
        content.sound = alarmPlaying && !critical
            ? nil
            : SoundCatalog.notificationSound(for: event.sound, critical: critical, volume: event.criticalVolume)
        if critical {
            content.interruptionLevel = .critical
        } else {
            content.interruptionLevel = event.sound == .silent && !event.isCritical ? .active : .timeSensitive
        }
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    func post(title: String, body: String, sound: SoundStyle = .tune(name: "chime")) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = SoundCatalog.notificationSound(for: sound, critical: false, volume: 1)
        content.interruptionLevel = .timeSensitive
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    /// Replaces the pending "no data" notifications. Called on every new reading.
    func scheduleMissingData(_ dates: [Date], config: MissingDataAlert) {
        let ids = (0..<MissingDataAlert.maxScheduledNotifications).map { "\(Self.missingDataPrefix)\($0)" }
        center.removePendingNotificationRequests(withIdentifiers: ids)
        for (index, date) in dates.enumerated() where index < ids.count {
            let content = UNMutableNotificationContent()
            content.title = "No glucose data"
            content.body = "No reading for \(config.minutes) min. Check the sensor and Bluetooth."
            content.sound = SoundCatalog.notificationSound(for: config.sound, critical: config.isCritical && criticalAllowed, volume: 1)
            content.interruptionLevel = config.isCritical && criticalAllowed ? .critical : .timeSensitive
            schedule(id: ids[index], content: content, at: date)
        }
    }

    func cancelMissingData() {
        center.removePendingNotificationRequests(withIdentifiers: (0..<MissingDataAlert.maxScheduledNotifications).map { "\(Self.missingDataPrefix)\($0)" })
    }

    func scheduleSensorReminders(_ reminders: [SensorLifecycle.Reminder]) {
        center.removePendingNotificationRequests(withIdentifiers: (0..<5).map { "\(Self.sensorPrefix)\($0)" })
        for (index, reminder) in reminders.enumerated() {
            let content = UNMutableNotificationContent()
            content.title = reminder.title
            content.body = reminder.body
            content.sound = SoundCatalog.notificationSound(for: .tune(name: "chime"), critical: false, volume: 1)
            content.interruptionLevel = .timeSensitive
            schedule(id: "\(Self.sensorPrefix)\(index)", content: content, at: reminder.date)
        }
    }

    /// "Sensor ready" when a newly started sensor finishes its 60-minute warm-up.
    func scheduleWarmUpDone(at date: Date) {
        center.removePendingNotificationRequests(withIdentifiers: ["sensor-warmup"])
        guard date > Date() else { return }
        let content = UNMutableNotificationContent()
        content.title = "Sensor ready"
        content.body = "Warm-up is finished. Glucose readings and alerts start now. Add a fingerstick to calibrate."
        content.sound = SoundCatalog.notificationSound(for: .tune(name: "chime"), critical: false, volume: 1)
        content.interruptionLevel = .timeSensitive
        schedule(id: "sensor-warmup", content: content, at: date)
    }

    /// Warns before a sideloaded app's signature expires (after that the app won't open or alert).
    func scheduleSignatureReminders(expiry: Date?) {
        center.removePendingNotificationRequests(withIdentifiers: (0..<2).map { "\(Self.signaturePrefix)\($0)" })
        guard let expiry else { return }
        let reminders = [(expiry.addingTimeInterval(-24 * 3600), "in 24 hours"), (expiry.addingTimeInterval(-2 * 3600), "in 2 hours")]
        for (index, (date, when)) in reminders.enumerated() where date > Date() {
            let content = UNMutableNotificationContent()
            content.title = "Glucose app expires \(when)"
            content.body = "Re-install it with Sideloadly before then, or the app stops opening and alerting."
            content.sound = .default
            content.interruptionLevel = .timeSensitive
            schedule(id: "\(Self.signaturePrefix)\(index)", content: content, at: date)
        }
    }

    private func schedule(id: String, content: UNNotificationContent, at date: Date) {
        let interval = max(1, date.timeIntervalSinceNow)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }

    // Show alerts even while the app is open.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.actionIdentifier == Self.snoozeAction,
           let idString = response.notification.request.content.userInfo["ruleID"] as? String,
           let id = UUID(uuidString: idString) {
            Task { @MainActor in self.onSnooze?(id) }
        }
        completionHandler()
    }
}
