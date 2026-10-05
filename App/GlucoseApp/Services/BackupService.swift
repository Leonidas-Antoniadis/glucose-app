import Foundation
import CryptoKit
import CommonCrypto
import Security
import GlucoseCore
import LibreProtocol

/// Everything needed to move to a new phone.
struct BackupPayload: Codable {
    var version = 1
    var createdAt: Date
    var settings: AppSettings
    var sensor: LibreSensorRecord?
    var logbook: [LogEntry]
    var fingersticks: [FingerstickEntry]
    var readings: [GlucoseReading]
}

/// Password-encrypted backup file: "GLBK", version, 16-byte salt, AES-GCM sealed JSON.
/// The key comes from PBKDF2-SHA256 with 200,000 rounds.
enum BackupService {
    private static let magic = Array("GLBK".utf8)
    private static let rounds: UInt32 = 200_000

    enum BackupError: LocalizedError {
        case notABackup
        case wrongPassword
        case keyDerivationFailed

        var errorDescription: String? {
            switch self {
            case .notABackup: return "That file isn't a Glucose backup."
            case .wrongPassword: return "Wrong password, or the file is damaged."
            case .keyDerivationFailed: return "Couldn't derive the encryption key."
            }
        }
    }

    static func write(_ payload: BackupPayload, password: String) throws -> URL {
        var salt = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, salt.count, &salt)
        let key = try deriveKey(password: password, salt: salt)
        let json = try JSONEncoder().encode(payload)
        guard let sealed = try AES.GCM.seal(json, using: key).combined else { throw BackupError.keyDerivationFailed }
        let data = Data(magic + [1] + salt) + sealed

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Glucose backup \(formatter.string(from: payload.createdAt)).glucosebackup")
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }

    static func read(from url: URL, password: String) throws -> BackupPayload {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        let bytes = [UInt8](data)
        guard bytes.count > 21, Array(bytes[0..<4]) == magic, bytes[4] == 1 else { throw BackupError.notABackup }
        let salt = Array(bytes[5..<21])
        let key = try deriveKey(password: password, salt: salt)
        do {
            let box = try AES.GCM.SealedBox(combined: Data(bytes[21...]))
            let json = try AES.GCM.open(box, using: key)
            return try JSONDecoder().decode(BackupPayload.self, from: json)
        } catch {
            throw BackupError.wrongPassword
        }
    }

    private static func deriveKey(password: String, salt: [UInt8]) throws -> SymmetricKey {
        guard !password.isEmpty else { throw BackupError.wrongPassword }
        var derived = [UInt8](repeating: 0, count: 32)
        let passwordBytes = Array(password.utf8)
        let status = passwordBytes.withUnsafeBufferPointer { passwordBuffer in
            passwordBuffer.baseAddress!.withMemoryRebound(to: CChar.self, capacity: passwordBytes.count) { passwordPointer in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    passwordPointer, passwordBytes.count,
                    salt, salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    rounds,
                    &derived, derived.count
                )
            }
        }
        guard status == Int32(kCCSuccess) else { throw BackupError.keyDerivationFailed }
        return SymmetricKey(data: derived)
    }
}
