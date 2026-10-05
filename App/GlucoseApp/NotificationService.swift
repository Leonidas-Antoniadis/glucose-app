import Foundation
import UserNotifications
import GlucoseCore

/// Delivers alert events as local notifications. Nothing leaves the phone.
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    private static let missingDataPrefix = "missing-data-"

    override init() {
        super.init()
        center.delegate = self
    }

    func requestAuthorization() async {
        // Add .criticalAlert here once Apple grants the Critical Alerts entitlement.
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    func deliver(_ event: AlertEvent, unit: GlucoseUnit) {
        let content = UNMutableNotificationContent()
        content.title = event.ruleName
        let value = unit.format(mgdL: event.valueMgdL, includeSymbol: true)
        switch event.kind {
        case .initial: content.body = "Glucose \(value)"
        case .reminder(let count): content.body = "Still \(value) (reminder \(count))"
        case .afterSnooze: content.body = "Still \(value) after snooze"
        }
        content.sound = Self.sound(for: event.sound)
        // Without the Critical Alerts entitlement, Time Sensitive is the strongest level available.
        content.interruptionLevel = event.sound == .silent ? .active : .timeSensitive
        content.threadIdentifier = event.direction.rawValue
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
            content.sound = Self.sound(for: config.sound)
            content.interruptionLevel = .timeSensitive
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, date.timeIntervalSinceNow), repeats: false)
            center.add(UNNotificationRequest(identifier: ids[index], content: content, trigger: trigger))
        }
    }

    /// Bundled tunes and voice clips come later; until then they use the default sound.
    private static func sound(for style: SoundStyle) -> UNNotificationSound? {
        switch style {
        case .silent: return nil
        case .tune, .voice: return .default
        }
    }

    // Show alerts even while the app is open.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
}
