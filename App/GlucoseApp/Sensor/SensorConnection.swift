import Foundation
import Observation
import GlucoseCore
import LibreProtocol

/// Owns the paired Libre sensor: NFC pairing and scans, the Bluetooth stream, calibration,
/// and the raw capture log used to debug the protocol on a real sensor.
@MainActor
@Observable
final class SensorConnection {
    enum Status: Equatable {
        case notPaired
        case searching
        case connecting
        case connected
        case warmingUp(until: Date)
        case ended
        case bluetoothOff
        case error(String)

        var title: String {
            switch self {
            case .notPaired: return "No sensor paired"
            case .searching: return "Searching for sensor…"
            case .connecting: return "Connecting…"
            case .connected: return "Connected"
            case .warmingUp: return "Warming up"
            case .ended: return "Sensor ended"
            case .bluetoothOff: return "Bluetooth is off"
            case .error(let message): return message
            }
        }
    }

    enum Event {
        case paired
        case bluetoothOff
        case sensorEnded
        case error(String)
    }

    struct RawSample: Equatable {
        let date: Date
        let raw: Double
    }

    private(set) var record: LibreSensorRecord?
    private(set) var status: Status = .notPaired
    private(set) var lastPacketAt: Date?
    private(set) var lastRaw: RawSample?
    private(set) var debugLog: [String] = []
    private(set) var isBusy = false
    var allowUnverifiedTypes = false

    @ObservationIgnored var onReadings: (@MainActor ([GlucoseReading], Bool) -> Void)?
    @ObservationIgnored var onEvent: (@MainActor (Event) -> Void)?
    @ObservationIgnored private let nfc = LibreNFCReader()
    @ObservationIgnored private let ble = LibreBLE()
    @ObservationIgnored private let stores: AppStores
    @ObservationIgnored private var running = false
    @ObservationIgnored private let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    init(stores: AppStores) {
        self.stores = stores
        record = stores.sensor.load()
        ble.knownPeripheralID = record?.peripheralIdentifier
        ble.onEvent = { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
        ble.unlockPayload = { [weak self] in
            MainActor.assumeIsolated { self?.makeUnlockPayload() }
        }
    }

    // MARK: Lifecycle

    func start() {
        running = true
        guard let record else {
            status = .notPaired
            return
        }
        if Date() >= record.expiresAt {
            status = .ended
            return
        }
        status = .searching
        ble.knownPeripheralID = record.peripheralIdentifier
        ble.start()
    }

    func stop() {
        running = false
        ble.stop()
    }

    func forget() {
        ble.resetForNewSensor()
        record = nil
        stores.sensor.delete()
        status = .notPaired
        lastPacketAt = nil
        lastRaw = nil
        log("Sensor forgotten")
    }

    /// Restores a sensor record from a backup (the sensor itself still needs to be in range).
    func restore(_ restored: LibreSensorRecord) {
        record = restored
        save()
        ble.resetForNewSensor()
        ble.knownPeripheralID = restored.peripheralIdentifier
        log("Sensor restored from backup")
    }

    // MARK: NFC

    /// Pairs with a running sensor: reads it, enables Bluetooth streaming, imports its history.
    func pair() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let scan = try await nfc.scan(enableStreaming: true, allowUnverified: allowUnverifiedTypes)
            capture("NFC uid", scan.uid)
            capture("NFC patch", scan.patchInfo)
            capture("NFC fram", scan.fram)
            if let response = scan.streamingResponse { capture("NFC enable", response) }

            let fram = try decodeFRAM(scan)
            guard fram.state == .active || fram.state == .warmingUp else {
                throw LibreProtocolError.unsupportedSensor("sensor state is \(fram.state.description)")
            }
            var newRecord = LibreSensorRecord(uid: scan.uid, patchInfo: scan.patchInfo, ageMinutes: fram.ageMinutes,
                                              maxLifeMinutes: fram.maxLifeMinutes, now: Date())
            // Re-pairing the same sensor keeps its calibration.
            if let old = record, old.uid == scan.uid {
                newRecord.calibrationPoints = old.calibrationPoints
                newRecord.calibration = Calibration.fit(old.calibrationPoints, now: Date())
            }
            record = newRecord
            save()
            log("Paired \(newRecord.type.displayName), serial \(newRecord.serial), age \(fram.ageMinutes) min")
            importFRAM(fram, record: newRecord)

            ble.resetForNewSensor()
            onEvent?(.paired)
            start()
        } catch NFCReadError.cancelled {
            log("NFC scan cancelled")
        } catch {
            fail(error)
        }
    }

    /// Reads the sensor's last 8 hours over NFC to fill gaps.
    func scanHistory() async {
        guard !isBusy else { return }
        guard let record else {
            status = .error("Pair a sensor first.")
            return
        }
        isBusy = true
        defer { isBusy = false }
        do {
            let scan = try await nfc.scan(enableStreaming: false, allowUnverified: allowUnverifiedTypes)
            capture("NFC fram", scan.fram)
            guard scan.uid == record.uid else {
                throw LibreProtocolError.unsupportedSensor("this is a different sensor; pair it instead")
            }
            let fram = try decodeFRAM(scan)
            importFRAM(fram, record: record)
            log("NFC scan imported \(fram.trend.count + fram.history.count) values")
        } catch NFCReadError.cancelled {
            log("NFC scan cancelled")
        } catch {
            fail(error)
        }
    }

    private func decodeFRAM(_ scan: LibreNFCReader.ScanResult) throws -> LibreFRAM {
        let decrypted = try Libre2Crypto.decryptFRAM(uid: scan.uid, patchInfo: scan.patchInfo, data: scan.fram)
        return try LibreFRAM(decrypted: decrypted)
    }

    private func importFRAM(_ fram: LibreFRAM, record: LibreSensorRecord) {
        if let latest = fram.trend.first {
            lastRaw = RawSample(date: record.timestamp(forMinute: latest.minuteIndex), raw: Double(latest.raw))
        }
        let trend = record.glucoseReadings(from: fram.trend, liveSource: .nfc)
        let history = record.glucoseReadings(from: fram.history, liveSource: .nfc)
        onReadings?(history + trend, true)
    }

    // MARK: Calibration

    /// Calibrates against a fingerstick taken now. Needs a raw value from the last 10 minutes.
    @discardableResult
    func calibrate(referenceMgdL: Double, at date: Date) -> Bool {
        guard var record, let lastRaw, abs(date.timeIntervalSince(lastRaw.date)) <= 10 * 60 else { return false }
        record.addCalibration(referenceMgdL: referenceMgdL, raw: lastRaw.raw, date: date)
        self.record = record
        save()
        log(String(format: "Calibrated: slope %.4f, intercept %.1f, %ld points",
                   record.calibration.slope, record.calibration.intercept, record.calibration.pointCount))
        return true
    }

    // MARK: Bluetooth

    private func handle(_ event: LibreBLE.Event) {
        switch event {
        case .poweredOff:
            status = .bluetoothOff
            if running, record != nil { onEvent?(.bluetoothOff) }
        case .unauthorized:
            status = .error("Bluetooth permission is off. Allow it in Settings.")
        case .scanning:
            status = .searching
            log("Scanning")
        case .connecting:
            if status != .connected { status = .connecting }
        case .connected(let id):
            log("Connected to \(id.uuidString.prefix(8))")
        case .disconnected:
            log("Disconnected, waiting to reconnect")
            if status == .connected { status = .connecting }
        case .packet(let packet, let id):
            handlePacket(packet, from: id)
        case .log(let message):
            log(message)
        }
    }

    private func makeUnlockPayload() -> [UInt8]? {
        guard var record else { return nil }
        do {
            let payload = try record.nextUnlockPayload()
            self.record = record
            save()
            return payload
        } catch {
            fail(error)
            return nil
        }
    }

    private func handlePacket(_ packet: [UInt8], from id: UUID) {
        guard var record else { return }
        capture("BLE", packet)
        do {
            let decrypted = try Libre2Crypto.decryptBLE(uid: record.uid, packet: packet)
            let parsed = try LibreBLEPacket(decrypted: decrypted)
            if record.peripheralIdentifier != id {
                record.peripheralIdentifier = id
                ble.confirm(id)
                log("Sensor confirmed")
            }
            // Keep the timeline anchored to the sensor's own clock.
            if abs(record.ageMinutes(at: Date()) - parsed.ageMinutes) > 2 {
                let aligned = (Date().timeIntervalSince1970 / 60).rounded(.down) * 60
                record.activatedAt = Date(timeIntervalSince1970: aligned - Double(parsed.ageMinutes) * 60)
            }
            self.record = record
            save()
            lastPacketAt = Date()
            if let latest = parsed.latest {
                lastRaw = RawSample(date: record.timestamp(forMinute: latest.minuteIndex), raw: Double(latest.raw))
            }

            if parsed.ageMinutes >= record.maxLifeMinutes {
                status = .ended
                ble.stop()
                onEvent?(.sensorEnded)
                return
            }
            status = parsed.ageMinutes < LibreSensorRecord.warmUpMinutes ? .warmingUp(until: record.warmUpEndsAt) : .connected
            let readings = record.glucoseReadings(from: parsed.history, liveSource: .bluetooth)
                + record.glucoseReadings(from: parsed.trend, liveSource: .bluetooth)
            onReadings?(readings, true)
        } catch {
            if record.peripheralIdentifier == id {
                log("Corrupt packet ignored: \(error)")
            } else {
                log("Packet from another device rejected")
                ble.reject(id)
            }
        }
    }

    // MARK: Helpers

    private func save() {
        guard let record else { return }
        try? stores.sensor.save(record)
    }

    private func fail(_ error: Error) {
        let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        status = .error(message)
        log("Error: \(message)")
        onEvent?(.error(message))
    }

    private func log(_ message: String) {
        debugLog.insert("\(timeFormatter.string(from: Date())) \(message)", at: 0)
        if debugLog.count > 200 { debugLog.removeLast(debugLog.count - 200) }
    }

    private func capture(_ kind: String, _ bytes: [UInt8]) {
        stores.appendCapture("\(ISO8601DateFormatter().string(from: Date())) | \(kind) | \(bytes.hexString)")
    }
}
