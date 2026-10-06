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
    case alreadyStarted(String)
    case startFailed(String)
    case startedNotPaired(String)
    case differentSensor

    var errorDescription: String? {
        switch self {
        case .differentSensor: return "This is a different sensor than the one paired. To use it, tap Pair sensor on the Sensor screen."
        case .undecodable: return "This sensor's data couldn't be decoded, so it was not paired. Nothing on the sensor was changed and LibreLink keeps working. Share the raw captures to help fix this."
        case .notReady(let state):
            let hint = state == LibreFRAM.State.notActivated.description ? " To use a new sensor, tap Start a new sensor." : ""
            return "The sensor can't be paired right now (state: \(state)). Nothing on the sensor was changed." + hint
        case .alreadyStarted(let state): return "This sensor isn't new (state: \(state)), so it wasn't started again. If it's running, use Pair sensor instead."
        case .startFailed(let detail): return "The sensor didn't start (\(detail)). You can still start it with LibreLink or the reader."
        case .startedNotPaired(let detail): return "The sensor started, but pairing didn't finish (\(detail)). Wait a minute, then tap Pair sensor."
        case .unavailable: return "NFC isn't available. It needs an iPhone 7 or later and an app signed with NFC permission (paid Apple Developer account)."
        case .notLibre: return "That tag isn't a Libre sensor."
        case .unsupported(let detail): return "This sensor isn't supported: \(detail). Only European Libre 2 and Libre 2 Plus sensors work."
        case .cancelled: return "Scan cancelled."
        case .failed(let message): return "Couldn't read the sensor: \(message)"
        }
    }
}

/// Reads a Libre sensor over NFC (ISO 15693): UID, patch info, the 344-byte FRAM, and
/// optionally starts a new sensor and sends the "enable Bluetooth streaming" command.
final class LibreNFCReader: NSObject, NFCTagReaderSessionDelegate {
    enum Mode {
        /// Read only; the sensor is left as it is.
        case read
        /// Take over the Bluetooth stream of a running sensor.
        case pair
        /// Start a new sensor, then pair it.
        case start
    }

    struct ScanResult {
        /// Sensor byte order (reverse of CoreNFC's identifier).
        let uid: [UInt8]
        let patchInfo: [UInt8]
        /// Encrypted FRAM.
        let fram: [UInt8]
        /// Response to the enable-streaming command (contains the BLE address).
        let streamingResponse: [UInt8]?
        /// Response to the start command, when this scan started the sensor.
        var activationResponse: [UInt8]? = nil
    }

    /// Receives raw bytes as they are read (also when decoding later fails), for the capture log.
    var onCapture: ((String, [UInt8]) -> Void)?

    struct RawRead {
        let uid: [UInt8]
        let patchInfo: [UInt8]
        let fram: [UInt8]
    }

    private var lastRead: RawRead?

    /// The bytes of the most recent read, even if it was aborted afterwards. Cleared when taken.
    func takeLastRead() -> RawRead? {
        lock.lock()
        defer { lock.unlock() }
        let read = lastRead
        lastRead = nil
        return read
    }

    private var continuation: CheckedContinuation<ScanResult, Error>?
    private var session: NFCTagReaderSession?
    private var mode = Mode.read
    private var allowUnverified = false
    private let lock = NSLock()

    @MainActor
    func scan(_ mode: Mode, allowUnverified: Bool) async throws -> ScanResult {
        guard NFCTagReaderSession.readingAvailable else { throw NFCReadError.unavailable }
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            self.lastRead = nil
            lock.unlock()
            self.mode = mode
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

    private func remember(_ read: RawRead) {
        lock.lock()
        lastRead = read
        lock.unlock()
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
        let mode = mode
        let allow = allowUnverified
        Task {
            do {
                try await session.connect(to: tag)
                let uid = Array(libreTag.identifier.reversed())

                var patchInfo = Array(try await libreTag.customCommand(
                    requestFlags: .highDataRate, customCommandCode: Int(Libre2Crypto.patchInfoCommand), customRequestParameters: Data()))
                if patchInfo.count > 6 { patchInfo = Array(patchInfo.suffix(6)) }
                let type = LibreSensorType(patchInfo: patchInfo)
                // Starting can't be undone, so it's only done on sensor types this app knows.
                guard type.isSupported || (allow && mode != .start) else {
                    throw NFCReadError.unsupported("\(type.displayName), patch info \(patchInfo.hexString)")
                }

                var fram = try await Self.readFRAM(libreTag)
                self.remember(RawRead(uid: uid, patchInfo: patchInfo, fram: fram))
                self.onCapture?("NFC uid", uid)
                self.onCapture?("NFC patch", patchInfo)
                self.onCapture?("NFC fram", fram)

                var activation: [UInt8]?
                if mode == .start {
                    let state: LibreFRAM.State
                    do {
                        state = try LibreFRAM.state(decrypted: Libre2Crypto.decryptFRAM(uid: uid, patchInfo: patchInfo, data: fram))
                    } catch {
                        throw NFCReadError.undecodable
                    }
                    guard state == .notActivated else { throw NFCReadError.alreadyStarted(state.description) }

                    let parameters = try Libre2Crypto.activateParameters(uid: uid)
                    do {
                        activation = Array(try await libreTag.customCommand(
                            requestFlags: .highDataRate, customCommandCode: Int(Libre2Crypto.activateCommand),
                            customRequestParameters: Data(parameters)))
                    } catch {
                        throw NFCReadError.startFailed("start command: \(error.localizedDescription)")
                    }
                    if let activation { self.onCapture?("NFC activate", activation) }

                    // Read again to confirm the sensor really started. The start command was accepted,
                    // so from here on the sensor has most likely started: every failure says so.
                    do {
                        fram = try await Self.readFRAM(libreTag)
                    } catch {
                        throw NFCReadError.startedNotPaired("the confirming read failed: \(error.localizedDescription)")
                    }
                    self.remember(RawRead(uid: uid, patchInfo: patchInfo, fram: fram))
                    self.onCapture?("NFC fram", fram)
                    let after = try? LibreFRAM.state(decrypted: Libre2Crypto.decryptFRAM(uid: uid, patchInfo: patchInfo, data: fram))
                    switch after {
                    case .some(.warmingUp), .some(.active): break
                    case .none: throw NFCReadError.startedNotPaired("its new state couldn't be read yet")
                    case .some(let state): throw NFCReadError.startFailed("state afterwards: \(state.description)")
                    }
                }

                var response: [UInt8]?
                if mode != .read {
                    do {
                        response = try await Self.enableStreaming(libreTag, uid: uid, patchInfo: patchInfo, fram: fram)
                    } catch {
                        guard mode == .start else { throw error }
                        // The .undecodable and .notReady texts say nothing on the sensor changed,
                        // which isn't true once it has started.
                        switch error as? NFCReadError {
                        case .some(.undecodable):
                            throw NFCReadError.startedNotPaired("the sensor's data isn't readable yet")
                        case .some(.notReady(let state)):
                            throw NFCReadError.startedNotPaired("sensor state: \(state)")
                        default:
                            throw NFCReadError.startedNotPaired((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
                        }
                    }
                }
                switch mode {
                case .read: session.alertMessage = "Sensor read."
                case .pair: session.alertMessage = "Sensor paired."
                case .start: session.alertMessage = "Sensor started and paired."
                }
                session.invalidate()
                self.finish(.success(ScanResult(uid: uid, patchInfo: patchInfo, fram: fram, streamingResponse: response,
                                                activationResponse: activation)))
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? "Couldn't read the sensor. Try again."
                session.invalidate(errorMessage: message)
                self.finish(.failure(error))
            }
        }
    }

    private static func readFRAM(_ tag: any NFCISO15693Tag) async throws -> [UInt8] {
        var fram: [UInt8] = []
        var block = 0
        while block < 43 {
            let count = min(8, 43 - block)
            let blocks = try await tag.readMultipleBlocks(
                requestFlags: .highDataRate, blockRange: NSRange(location: block, length: count))
            for data in blocks { fram += data }
            block += count
        }
        return fram
    }

    /// Proves the sensor's data decodes before taking over its Bluetooth link.
    /// If it doesn't, nothing is sent: the sensor and LibreLink are left untouched.
    private static func enableStreaming(_ tag: any NFCISO15693Tag, uid: [UInt8], patchInfo: [UInt8],
                                        fram: [UInt8]) async throws -> [UInt8] {
        let decrypted: [UInt8]
        do {
            decrypted = try Libre2Crypto.decryptFRAM(uid: uid, patchInfo: patchInfo, data: fram)
        } catch {
            throw NFCReadError.undecodable
        }
        // A never-started sensor may not have a decodable body yet, so check its state from the header first.
        if let state = try? LibreFRAM.state(decrypted: decrypted), state != .active && state != .warmingUp {
            throw NFCReadError.notReady(state.description)
        }
        do {
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
        return Array(try await tag.customCommand(
            requestFlags: .highDataRate, customCommandCode: Int(Libre2Crypto.enableStreamingCommand),
            customRequestParameters: Data(parameters)))
    }
}
