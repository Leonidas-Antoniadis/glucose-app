import Foundation
import AppIntents

/// What a Lock Screen button asks the app to do with a sounding alert.
enum AlertIntentAction: String {
    case snooze
    /// Snooze, and log that a low is being treated.
    case treating
}

/// Hands Live Activity button taps to the app. The intents run in the app's process (they are
/// LiveActivityIntents); in the widget extension nothing listens. A tap that arrives while the
/// app is still starting waits until the app's model is ready.
@MainActor
final class AlertIntentBridge {
    static let shared = AlertIntentBridge()

    private var pending: [(AlertIntentAction, UUID)] = []

    var handler: ((AlertIntentAction, UUID) -> Void)? {
        didSet {
            guard let handler else { return }
            let waiting = pending
            pending = []
            for (action, ruleID) in waiting { handler(action, ruleID) }
        }
    }

    func receive(_ action: AlertIntentAction, ruleID: UUID) {
        if let handler {
            handler(action, ruleID)
        } else {
            pending.append((action, ruleID))
        }
    }
}

/// The Live Activity's Snooze button.
struct SnoozeAlertIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Snooze glucose alert"

    @Parameter(title: "Alert")
    var ruleID: String

    init() {}

    init(ruleID: String) {
        self.ruleID = ruleID
    }

    func perform() async throws -> some IntentResult {
        if let id = UUID(uuidString: ruleID) {
            await AlertIntentBridge.shared.receive(.snooze, ruleID: id)
        }
        return .result()
    }
}

/// The Live Activity's Treating button, for a low: snoozes it and logs the treatment.
struct TreatingLowIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Treating a low"

    @Parameter(title: "Alert")
    var ruleID: String

    init() {}

    init(ruleID: String) {
        self.ruleID = ruleID
    }

    func perform() async throws -> some IntentResult {
        if let id = UUID(uuidString: ruleID) {
            await AlertIntentBridge.shared.receive(.treating, ruleID: id)
        }
        return .result()
    }
}
