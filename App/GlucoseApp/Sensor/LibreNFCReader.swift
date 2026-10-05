import Foundation
import CoreNFC
import LibreProtocol

enum NFCReadError: LocalizedError {
    case unavailable
    case notLibre
    case unsupported(String)
    case cancelled
    case failed(String)
    case undecodable
    case notReady(String)

    var errorDescription: String? {
        switch self {
        case .undecodable: return "This sensor's data couldn't be decoded, so it was not paired. Nothing on the sensor was changed and LibreLink keeps working. Share the raw captures to help fix this."
        case .notReady(let state): return "The sensor can't be paired right now (state: \(state)). Nothing on the sensor was changed."
        case .unavailable: return "NFC isn't available. It needs an iPhone 7 or later and an app signed with NFC permission (paid Apple Developer account)."
        case .notLibre: return "That tag isn't a Libre sensor."
        case .unsupported(let detail): return "This sensor isn't supported: \(detail). Only European Libre 2 and Libre 2 Plus sensors work."
        case .cancelled: return "Scan cancelled."
        case .failed(let message): return "Couldn't read the sensor: \(message)"
        }
    }
}

/// Reads a Libre sensor over NFC (ISO 15693): UID, patch info, the 344-byte FRAM, and
/// optionally sends the "enable Bluetooth streaming" command.
final class LibreNFCReader: NSObject, NFCTagReaderSessionDelegate {
    struct ScanResult {
        /// Sensor byte order (reverse of CoreNFC's identifier).
        let uid: [UInt8]
        let patchInfo: [UInt8]
        /// Encrypted FRAM.
        let fram: [UInt8]
        /// Response to the enable-streaming command (contains the BLE address).
        let streamingResponse: [UInt8]?
    }

    /// Receives raw bytes as they are read (also when decoding later fails), for the capture log.
    var onCapture: ((String, [UInt8]) -> Void)?

    private var continuation: CheckedContinuation<ScanResult, Error>?
    private var session: NFCTagReaderSession?
    private var enableStreaming = false
    private var allowUnverified = false
    private let lock = NSLock()

    @MainActor
    func scan(enableStreaming: Bool, allowUnverified: Bool) async throws -> ScanResult {
        guard NFCTagReaderSession.readingAvailable else { throw NFCReadError.unavailable }
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()
            self.enableStreaming = enableStreaming
            self.allowUnverified = allowUnverified
            let session = NFCTagReaderSession(pollingOption: .iso15693, delegate: self, queue: nil)
            session?.alertMessage = "Hold the top of your iPhone near the sensor."
            self.session = session
            session?.begin()
        }
    }

    private func finish(_ result: Result<ScanResult, Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
    }

    func tagReaderSessionDidBecomeActive(_ session: NFCTagReaderSession) {}

    func tagReaderSession(_ session: NFCTagReaderSession, didInvalidateWithError error: Error) {
        if let nfcError = error as? NFCReaderError, nfcError.code == .readerSessionInvalidationErrorUserCanceled {
            finish(.failure(NFCReadError.cancelled))
        } else {
            finish(.failure(NFCReadError.failed(error.localizedDescription)))
        }
    }

    func tagReaderSession(_ session: NFCTagReaderSession, didDetect tags: [NFCTag]) {
        guard let tag = tags.first, case .iso15693(let libreTag) = tag else {
            session.invalidate(errorMessage: NFCReadError.notLibre.localizedDescription)
            finish(.failure(NFCReadError.notLibre))
            return
        }
        let enable = enableStreaming
        let allow = allowUnverified
        Task {
            do {
                try await session.connect(to: tag)
                let uid = Array(libreTag.identifier.reversed())

                var patchInfo = Array(try await libreTag.customCommand(
                    requestFlags: .highDataRate, customCommandCode: Int(Libre2Crypto.patchInfoCommand), customRequestParameters: Data()))
                if patchInfo.count > 6 { patchInfo = Array(patchInfo.suffix(6)) }
                let type = LibreSensorType(patchInfo: patchInfo)
                guard type.isSupported || allow else {
                    throw NFCReadError.unsupported("\(type.displayName), patch info \(patchInfo.hexString)")
                }

                var fram: [UInt8] = []
                var block = 0
                while block < 43 {
                    let count = min(8, 43 - block)
                    let blocks = try await libreTag.readMultipleBlocks(
                        requestFlags: .highDataRate, blockRange: NSRange(location: block, length: count))
                    for data in blocks { fram += data }
                    block += count
                }
                self.onCapture?("NFC uid", uid)
                self.onCapture?("NFC patch", patchInfo)
                self.onCapture?("NFC fram", fram)

                var response: [UInt8]?
                if enable {
                    // Prove the sensor's data decodes before taking over its Bluetooth link.
                    // If it doesn't, stop here: the sensor and LibreLink are left untouched.
                    do {
                        let decrypted = try Libre2Crypto.decryptFRAM(uid: uid, patchInfo: patchInfo, data: fram)
                        let decoded = try LibreFRAM(decrypted: decrypted)
                        guard decoded.state == .active || decoded.state == .warmingUp else {
                            throw NFCReadError.notReady(decoded.state.description)
                        }
                    } catch let error as NFCReadError {
                        throw error
                    } catch {
                        throw NFCReadError.undecodable
                    }
                    let parameters = try Libre2Crypto.enableStreamingParameters(uid: uid, patchInfo: patchInfo)
                    response = Array(try await libreTag.customCommand(
                        requestFlags: .highDataRate, customCommandCode: Int(Libre2Crypto.enableStreamingCommand),
                        customRequestParameters: Data(parameters)))
                }
                session.alertMessage = enable ? "Sensor paired." : "Sensor read."
                session.invalidate()
                self.finish(.success(ScanResult(uid: uid, patchInfo: patchInfo, fram: fram, streamingResponse: response)))
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? "Couldn't read the sensor. Try again."
                session.invalidate(errorMessage: message)
                self.finish(.failure(error))
            }
        }
    }
}
