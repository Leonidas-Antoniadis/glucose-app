import Foundation
import AVFoundation
import LocalAuthentication
import GlucoseCore

/// Speaks the value with an alert while the app is open (iOS doesn't allow speech from a notification).
@MainActor
final class VoiceAnnouncer {
    private let synthesizer = AVSpeechSynthesizer()

    func announce(_ event: AlertEvent, unit: GlucoseUnit) {
        let value = unit == .mgdL
            ? "\(Int(event.valueMgdL.rounded()))"
            : String(format: "%.1f", unit.fromMgdL(event.valueMgdL))
        let utterance = AVSpeechUtterance(string: "\(event.ruleName). Glucose \(value).")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.9
        synthesizer.speak(utterance)
    }
}

/// Reads the expiry date of the provisioning profile Sideloadly or Xcode embedded in the app.
enum ProvisioningProfile {
    static func expirationDate() -> Date? {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8)) else { return nil }
        let plistData = data.subdata(in: start.lowerBound..<end.upperBound)
        let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any]
        return plist?["ExpirationDate"] as? Date
    }
}

enum BiometricLock {
    /// Face ID / Touch ID with passcode fallback. Returns true when unlocked.
    static func authenticate() async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return true }
        return (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock your glucose data")) ?? false
    }
}
