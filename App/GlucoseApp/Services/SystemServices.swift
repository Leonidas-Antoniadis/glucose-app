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

/// When this build stops opening: the expiry of the provisioning profile Sideloadly or Xcode
/// embedded in the app, or for a TestFlight build (which has no profile) 90 days after it was built.
enum ProvisioningProfile {
    static func expirationDate() -> Date? {
        embeddedProfileExpiry() ?? testFlightExpiry()
    }

    /// TestFlight installs carry a sandbox receipt instead of an embedded profile.
    static var isTestFlight: Bool {
        Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision") == nil
            && Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt"
    }

    private static func embeddedProfileExpiry() -> Date? {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8)) else { return nil }
        let plistData = data.subdata(in: start.lowerBound..<end.upperBound)
        let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any]
        return plist?["ExpirationDate"] as? Date
    }

    /// The TestFlight upload stamps the build number as the UTC build time, yyyyMMddHHmm, and
    /// TestFlight builds expire 90 days after upload.
    private static func testFlightExpiry() -> Date? {
        guard isTestFlight,
              let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
              build.count == 12, build.allSatisfy(\.isNumber) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMddHHmm"
        return formatter.date(from: build)?.addingTimeInterval(90 * 86_400)
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
