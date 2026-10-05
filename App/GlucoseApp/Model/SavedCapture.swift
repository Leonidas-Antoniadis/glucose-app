import Foundation
import LibreProtocol

/// A Bluetooth packet or NFC read you chose to keep on the phone (or a failed pairing,
/// kept automatically for troubleshooting). Stores the bytes as received plus what's
/// needed to decode them again.
struct SavedCapture: Codable, Identifiable, Hashable {
    enum Kind: String, Codable {
        case bluetooth
        case nfc
    }

    var id = UUID()
    var date: Date
    var kind: Kind
    var uid: [UInt8]
    var patchInfo: [UInt8]
    /// Bytes as received (encrypted).
    var bytes: [UInt8]
    /// Response to the NFC enable-streaming command, if any.
    var enableResponse: [UInt8]?
    var isSimulated: Bool
    /// Why it was saved ("Saved by you", "Pairing failed: …").
    var reason: String

    var title: String {
        let source = kind == .bluetooth ? "Bluetooth packet" : "NFC read"
        return isSimulated ? "\(source) (demo)" : source
    }

    /// Plain-text export, one block per capture, readable without the app.
    static func exportText(_ captures: [SavedCapture]) -> String {
        let iso = ISO8601DateFormatter()
        return captures.map { capture in
            var lines = [
                "# \(capture.title), \(iso.string(from: capture.date))",
                "reason: \(capture.reason)",
                "uid: \(capture.uid.hexString)",
                "patchInfo: \(capture.patchInfo.hexString)",
                "bytes(\(capture.bytes.count)): \(capture.bytes.hexString)",
            ]
            if let response = capture.enableResponse {
                lines.append("enableResponse: \(response.hexString)")
            }
            return lines.joined(separator: "\n")
        }
        .joined(separator: "\n\n") + "\n"
    }
}
