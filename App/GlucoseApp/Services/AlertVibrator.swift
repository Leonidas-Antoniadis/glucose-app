import AudioToolbox
import UIKit

/// Keeps the phone vibrating after an alert. In Silent mode iOS buzzes only once for a notification,
/// however long its sound is, so the app vibrates itself for the chosen time (Alerts → Vibration).
/// Works while the app runs: on screen, or woken in the background by a Bluetooth reading.
/// iOS only vibrates if Settings → Sounds & Haptics allows haptics in Silent mode.
@MainActor
final class AlertVibrator {
    static let allowedSeconds = [0, 5, 10, 20, 30]

    private var task: Task<Void, Never>?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    /// Vibrates about once a second for `seconds`. A new alert restarts the time.
    func start(seconds: Int) {
        stop()
        guard seconds > 0 else { return }
        // A Bluetooth wake leaves the app only a few seconds; this asks iOS for the rest of the time.
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Alert vibration") { [weak self] in
            MainActor.assumeIsolated { self?.stop() }
        }
        let end = Date().addingTimeInterval(Double(seconds))
        task = Task { [weak self] in
            while !Task.isCancelled, Date() < end {
                AudioServicesPlayAlertSound(kSystemSoundID_Vibrate)
                try? await Task.sleep(for: .seconds(1))
            }
            guard !Task.isCancelled else { return }
            self?.stop()
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }
}
