import Foundation
import UserNotifications
import GlucoseCore

/// Local notifications only. Nothing leaves the phone.
/// On the main actor: `criticalAllowed` is written when the status is refreshed and read when an
/// alert is delivered, and both must happen on one thread.
@MainActor
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    static let alertCategory = "GLUCOSE_ALERT"
    /// Low alerts also offer Treating.
    static let lowAlertCategory = "GLUCOSE_ALERT_LOW"
    static let snoozeAction = "SNOOZE"
    static let treatingAction = "TREATING"
    private static let missingDataPrefix = "missing-data-"
    private static let sensorPrefix = "sensor-reminder-"
    private static let signaturePrefix = "signature-"
    private static let demoPrefix = "demo-alert-"
    private static let repeatPrefix = "alert-repeat-"
    /// The follow-ups of the newest alert, so a newer alert or a snooze can cancel them.
    private var repeatIDs: [String] = []
    /// iOS keeps at most 64 pending notifications; leave room for the others.
    static let maxDemoAlerts = 30

    /// Called when the user taps Snooze on an alert notification, with the time the alert was sent.
    var onSnooze: (@MainActor (UUID, Date?) -> Void)?
    /// Called when the user taps Treating on a low alert notification.
    var onTreating: (@MainActor (UUID, Date?) -> Void)?

    /// Richer words and a 2-hour chart for an alert notification.
    struct AlertDetails {
        var title: String
        var body: String
        var chartURL: URL?
    }
    /// True once Apple's Critical Alerts entitlement is granted and the user allowed it.
    private(set) var criticalAllowed = false

    override init() {
        super.init()
        center.delegate = self
        let snooze = UNNotificationAction(identifier: Self.snoozeAction, title: "Snooze", options: [],
                                          icon: UNNotificationActionIcon(systemImageName: "bell.slash"))
        let treating = UNNotificationAction(identifier: Self.treatingAction, title: "Treating", options: [],
                                            icon: UNNotificationActionIcon(systemImageName: "drop.fill"))
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.alertCategory, actions: [snooze], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: Self.lowAlertCategory, actions: [treating, snooze], intentIdentifiers: [], options: []),
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

    /// `alarmPlaying`: the app is already playing the sound itself, loud enough to hear, so the
    /// notification stays quiet.
    /// `isTest`: a test alert gets no Snooze or Treating, so tapping them can't snooze the real
    /// rule or log a treatment.
    /// `repeats`: copies of the alert sent `interval` seconds apart. In Silent mode iOS buzzes once
    /// per notification, so each copy is one more buzz. They're scheduled with iOS, so they come
    /// even if the app is suspended right after.
    func deliver(_ event: AlertEvent, unit: GlucoseUnit, alarmPlaying: Bool = false, details: AlertDetails? = nil,
                 isTest: Bool = false, repeats: (count: Int, interval: Int)? = nil) {
        let content = content(for: event, unit: unit, alarmPlaying: alarmPlaying)
        if isTest {
            content.categoryIdentifier = ""
            content.userInfo = [:]
        }
        if let repeats, repeats.count > 0 {
            // A copy always has a sound: iOS only vibrates for a notification that has one.
            let copy = self.content(for: event, unit: unit, alarmPlaying: false)
            copy.categoryIdentifier = content.categoryIdentifier
            copy.userInfo = content.userInfo
            if let details {
                copy.title = details.title
                copy.body = details.body
            }
            scheduleRepeats(of: copy, count: repeats.count, interval: repeats.interval)
        }
        var chartFile: URL?
        if let details {
            content.title = details.title
            content.body = details.body
            if let url = details.chartURL {
                if let chart = try? UNNotificationAttachment(identifier: "chart", url: url, options: nil) {
                    content.attachments = [chart]
                    chartFile = url
                } else {
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }
        let attached = chartFile
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) { error in
            // iOS takes the chart file only when the notification is added.
            if error != nil, let attached { try? FileManager.default.removeItem(at: attached) }
        }
    }

    private func scheduleRepeats(of content: UNNotificationContent, count: Int, interval: Int) {
        cancelRepeats()
        let base = Self.repeatPrefix + UUID().uuidString
        for index in 1...count {
            let id = "\(base)-\(index)"
            repeatIDs.append(id)
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: Double(index * max(1, interval)), repeats: false)
            center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
        }
    }

    /// Stops an alert's remaining extra buzzes and clears the copies already shown (the first alert stays).
    func cancelRepeats() {
        center.removePendingNotificationRequests(withIdentifiers: repeatIDs)
        center.removeDeliveredNotifications(withIdentifiers: repeatIDs)
        repeatIDs = []
        // Copies left from before the app was relaunched.
        let prefix = Self.repeatPrefix
        center.getDeliveredNotifications { [center] delivered in
            let old = delivered.map(\.request.identifier).filter { $0.hasPrefix(prefix) }
            if !old.isEmpty { center.removeDeliveredNotifications(withIdentifiers: old) }
        }
    }

    /// Demo only: the alerts the simulated sensor will raise while iOS keeps the app suspended.
    func scheduleDemoAlerts(_ events: [AlertEvent], unit: GlucoseUnit) {
        cancelDemoAlerts()
        for (index, event) in events.prefix(Self.maxDemoAlerts).enumerated() {
            schedule(id: "\(Self.demoPrefix)\(index)", content: content(for: event, unit: unit, alarmPlaying: false), at: event.date)
        }
    }

    func cancelDemoAlerts() {
        let ids = (0..<Self.maxDemoAlerts).map { "\(Self.demoPrefix)\($0)" }
        center.removePendingNotificationRequests(withIdentifiers: ids)
        center.removeDeliveredNotifications(withIdentifiers: ids)
    }

    private func content(for event: AlertEvent, unit: GlucoseUnit, alarmPlaying: Bool) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = event.ruleName
        let value = unit.formatReading(mgdL: event.valueMgdL, includeSymbol: true)
        switch event.kind {
        case .initial: content.body = "Glucose \(value)"
        case .reminder(let count): content.body = "Still \(value) (reminder \(count))"
        case .afterSnooze: content.body = "Still \(value) after snooze"
        }
        content.categoryIdentifier = event.direction == .low ? Self.lowAlertCategory : Self.alertCategory
        content.userInfo = ["ruleID": event.ruleID.uuidString]
        content.threadIdentifier = event.direction.rawValue
        let critical = event.isCritical && criticalAllowed
        let sound = SoundCatalog.playable(event.sound, fallback: SoundCatalog.alarm(for: event.direction))
        content.sound = alarmPlaying && !critical
            ? nil
            : SoundCatalog.notificationSound(for: sound, critical: critical, volume: event.criticalVolume)
        if critical {
            content.interruptionLevel = .critical
        } else {
            content.interruptionLevel = event.sound == .silent && !event.isCritical ? .active : .timeSensitive
        }
        return content
    }

    func post(title: String, body: String, sound: SoundStyle = .tune(name: "chime")) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = SoundCatalog.notificationSound(for: sound, critical: false, volume: 1)
        content.interruptionLevel = .timeSensitive
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    private static let bedtimeID = "bedtime-check"

    /// The bedtime reminder, scheduled ahead so it fires even if no reading arrives tonight (with
    /// Bluetooth off or the app closed, the app can't check anything itself). A check the app
    /// runs before bedtime replaces it.
    func scheduleBedtimeReminder(at date: Date) {
        cancelBedtimeReminder()
        let content = UNMutableNotificationContent()
        content.title = "Bedtime check"
        content.body = "Glucose couldn't check tonight's alarms: no recent reading. Open the app to make sure they'll sound."
        content.sound = SoundCatalog.notificationSound(for: .tune(name: "chime"), critical: false, volume: 1)
        content.interruptionLevel = .timeSensitive
        schedule(id: Self.bedtimeID, content: content, at: date)
    }

    func cancelBedtimeReminder() {
        center.removePendingNotificationRequests(withIdentifiers: [Self.bedtimeID])
    }

    private static var missingDataIDs: [String] {
        (0..<MissingDataAlert.maxScheduledNotifications).map { "\(missingDataPrefix)\($0)" }
    }

    /// Replaces the pending "no data" notifications. Called on every new reading. Dates already
    /// past are skipped: scheduled now, they would fire a second later.
    func scheduleMissingData(_ dates: [Date], lastReading: Date, config: MissingDataAlert) {
        let ids = Self.missingDataIDs
        center.removePendingNotificationRequests(withIdentifiers: ids)
        for (index, date) in dates.filter({ $0 > Date() }).enumerated() where index < ids.count {
            let content = UNMutableNotificationContent()
            content.title = "No glucose data"
            content.body = MissingDataAlert.message(firingAt: date, lastReading: lastReading)
            let sound = SoundCatalog.playable(config.sound, fallback: .tune(name: "chime"))
            content.sound = SoundCatalog.notificationSound(for: sound, critical: config.isCritical && criticalAllowed, volume: 1)
            content.interruptionLevel = config.isCritical && criticalAllowed ? .critical : .timeSensitive
            schedule(id: ids[index], content: content, at: date)
        }
    }

    func cancelMissingData() {
        center.removePendingNotificationRequests(withIdentifiers: Self.missingDataIDs)
    }

    /// Clears "No glucose data" notifications already on the Lock Screen once readings are back.
    func clearDeliveredMissingData() {
        center.removeDeliveredNotifications(withIdentifiers: Self.missingDataIDs)
    }

    private static var sensorReminderIDs: [String] {
        (0..<5).map { "\(sensorPrefix)\($0)" } + ["sensor-warmup"]
    }

    /// Cancels the sensor-ending reminders and "Sensor ready", pending and delivered (the sensor
    /// was forgotten, or it ended and the app says so itself).
    func cancelSensorReminders() {
        center.removePendingNotificationRequests(withIdentifiers: Self.sensorReminderIDs)
        center.removeDeliveredNotifications(withIdentifiers: Self.sensorReminderIDs)
    }

    /// Removes everything this app has shown or scheduled (Delete all data).
    func removeAll() {
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()
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
            content.body = ProvisioningProfile.isTestFlight
                ? "Install a newer build from TestFlight before then, or the app stops opening and alerting."
                : "Re-install it with Sideloadly before then, or the app stops opening and alerting."
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
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let idString = response.notification.request.content.userInfo["ruleID"] as? String,
           let id = UUID(uuidString: idString) {
            let sentAt = response.notification.date
            let action = response.actionIdentifier
            // Done only once the snooze is saved, or iOS may suspend the app first.
            Task { @MainActor in
                switch action {
                case Self.snoozeAction: self.onSnooze?(id, sentAt)
                case Self.treatingAction: self.onTreating?(id, sentAt)
                default: break
                }
                completionHandler()
            }
            return
        }
        completionHandler()
    }
}
