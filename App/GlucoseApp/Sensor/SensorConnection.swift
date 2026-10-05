import Foundation
import Observation
import GlucoseCore
import LibreProtocol

/// Owns the paired Libre sensor: NFC pairing and scans, the Bluetooth stream, calibration,
/// the sensor history, and the raw packet logs shown in the data inspector.
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

    /// One Bluetooth packet as received and as decoded.
    struct PacketRecord: Identifiable {
        let id = UUID()
        let date: Date
        let encrypted: [UInt8]
        let decrypted: [UInt8]?
        let packet: LibreBLEPacket?
        let readings: [GlucoseReading]
        let error: String?
        let isSimulated: Bool
    }

    /// One NFC read as received and as decoded.
    struct NFCRecord: Identifiable {
        let id = UUID()
        let date: Date
        let uid: [UInt8]
        let patchInfo: [UInt8]
        let encrypted: [UInt8]
        let decrypted: [UInt8]?
        let fram: LibreFRAM?
        let streamingResponse: [UInt8]?
        let error: String?
        let isSimulated: Bool

        var sensorType: LibreSensorType { LibreSensorType(patchInfo: patchInfo) }
    }

    static let packetLogLimit = 200

    private(set) var record: LibreSensorRecord?
    private(set) var status: Status = .notPaired
    private(set) var lastPacketAt: Date?
    private(set) var lastRaw: RawSample?
    private(set) var debugLog: [String] = []
    private(set) var isBusy = false
    private(set) var packets: [PacketRecord] = []
    private(set) var nfcRecords: [NFCRecord] = []
    private(set) var history: SensorHistory
    /// A made-up sensor used in demo mode, so the inspector shows realistic bytes.
    private(set) var demoRecord: LibreSensorRecord?
    var allowUnverifiedTypes = false

    @ObservationIgnored var onReadings: (@MainActor ([GlucoseReading], Bool) -> Void)?
    @ObservationIgnored var onEvent: (@MainActor (Event) -> Void)?
    @ObservationIgnored private let nfc = LibreNFCReader()
    @ObservationIgnored private let ble = LibreBLE()
    @ObservationIgnored private let stores: AppStores
    @ObservationIgnored private var running = false
    @ObservationIgnored private var demoRaw: ((Int) -> Int)?
    @ObservationIgnored private let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    init(stores: AppStores) {
        self.stores = stores
        record = stores.sensor.load()
        history = stores.sensorHistory.load() ?? SensorHistory()
        ble.knownPeripheralID = record?.peripheralIdentifier
        nfc.onCapture = { [stores] kind, bytes in
            stores.appendCapture("\(ISO8601DateFormatter().string(from: Date())) | \(kind) | \(bytes.hexString)")
        }
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
        if let record {
            history.markEnded(id: record.uid.hexString, at: Date(), reason: Date() >= record.expiresAt ? .expired : .removedEarly)
            saveHistory()
        }
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
            if let response = scan.streamingResponse { capture("NFC enable", response) }
            let fram = try decodeAndLog(scan)
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
            history.record(SensorHistoryEntry(
                id: newRecord.uid.hexString, sensorType: newRecord.type.displayName, computedSerial: newRecord.serial,
                uidHex: newRecord.uid.hexString, patchInfoHex: newRecord.patchInfo.hexString,
                startedAt: newRecord.activatedAt, pairedAt: Date(), expectedEnd: newRecord.expiresAt
            ), at: Date())
            saveHistory()
            log("Paired \(newRecord.type.displayName), serial \(newRecord.serial), age \(fram.ageMinutes) min")
            importFRAM(fram, record: newRecord)

            ble.resetForNewSensor()
            onEvent?(.paired)
            start()
        } catch NFCReadError.cancelled {
            log("NFC scan cancelled")
        } catch {
            logFailedRead(error)
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
            let fram = try decodeAndLog(scan)
            guard scan.uid == record.uid else {
                throw LibreProtocolError.unsupportedSensor("this is a different sensor; pair it instead")
            }
            if fram.state == .failure {
                history.markEnded(id: record.uid.hexString, at: Date(), reason: .failed)
                saveHistory()
            }
            importFRAM(fram, record: record)
            log("NFC scan imported \(fram.trend.count + fram.history.count) values")
        } catch NFCReadError.cancelled {
            log("NFC scan cancelled")
        } catch {
            logFailedRead(error)
            fail(error)
        }
    }

    /// Decodes a scan and adds it to the NFC log, also when decoding fails.
    private func decodeAndLog(_ scan: LibreNFCReader.ScanResult) throws -> LibreFRAM {
        do {
            let decrypted = try Libre2Crypto.decryptFRAM(uid: scan.uid, patchInfo: scan.patchInfo, data: scan.fram)
            let fram = try LibreFRAM(decrypted: decrypted)
            appendNFC(NFCRecord(date: Date(), uid: scan.uid, patchInfo: scan.patchInfo, encrypted: scan.fram, decrypted: decrypted,
                                fram: fram, streamingResponse: scan.streamingResponse, error: nil, isSimulated: false))
            return fram
        } catch {
            appendNFC(NFCRecord(date: Date(), uid: scan.uid, patchInfo: scan.patchInfo, encrypted: scan.fram, decrypted: nil,
                                fram: nil, streamingResponse: scan.streamingResponse, error: "\(error)", isSimulated: false))
            throw error
        }
    }

    /// When the reader aborted (e.g. the data didn't decode), log the bytes it did read.
    private func logFailedRead(_ error: Error) {
        guard let raw = nfc.takeLastRead() else { return }
        let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        let decrypted = try? Libre2Crypto.decryptFRAM(uid: raw.uid, patchInfo: raw.patchInfo, data: raw.fram)
        appendNFC(NFCRecord(date: Date(), uid: raw.uid, patchInfo: raw.patchInfo, encrypted: raw.fram, decrypted: decrypted,
                            fram: decrypted.flatMap { try? LibreFRAM(decrypted: $0) }, streamingResponse: nil,
                            error: message, isSimulated: false))
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

    // MARK: Sensor history

    func updateHistory(_ entry: SensorHistoryEntry) {
        history.update(entry)
        saveHistory()
    }

    /// Adds a sensor used outside this app (e.g. with LibreLink), so its details are on file too.
    func addManualSensor(_ entry: SensorHistoryEntry) {
        var history = self.history
        history.record(entry, at: entry.pairedAt ?? Date())
        // A manually added sensor shouldn't close the one this app is reading.
        if let current = record, let index = history.entries.firstIndex(where: { $0.id == current.uid.hexString }),
           history.entries[index].endReason == .replaced {
            var reopened = history.entries[index]
            reopened.endedAt = nil
            reopened.endReason = nil
            history.update(reopened)
        }
        self.history = history
        saveHistory()
    }

    func removeHistory(id: String) {
        history.remove(id: id)
        saveHistory()
    }

    /// Example sensors for CI screenshots. Kept in memory only.
    func seedSampleHistory(now: Date) {
        let samples: [(serial: String, startDays: Double, endDays: Double?, reason: SensorHistoryEntry.EndReason?, note: String)] = [
            ("0M00A1B2C3", 60, 45, .expired, ""),
            ("0M00D4E5F6", 45, 36, .fellOff, "Came off in the shower on day 9"),
            ("0M00G7H8J9", 36, 30, .failed, "\"Sensor error\" after 6 days, replaced by support"),
            ("0M00K1L2M3", 30, 15.5, .expired, ""),
            ("0M00N4P5Q6", 15, nil, nil, "Left arm"),
        ]
        var sample = SensorHistory()
        for (index, item) in samples.enumerated() {
            let start = now.addingTimeInterval(-item.startDays * 86_400)
            var uid = LibreSimulator.demoUID
            uid[0] &+= UInt8(index * 17)
            sample.record(SensorHistoryEntry(
                id: uid.hexString, sensorType: "Libre 2 Plus (EU)",
                computedSerial: "3" + item.serial.dropFirst(), printedSerial: item.serial,
                uidHex: uid.hexString, patchInfoHex: LibreSimulator.demoPatchInfo.hexString,
                startedAt: start, pairedAt: start.addingTimeInterval(3600), expectedEnd: start.addingTimeInterval(15 * 86_400),
                endedAt: item.endDays.map { now.addingTimeInterval(-$0 * 86_400) }, endReason: item.reason, note: item.note
            ), at: start)
        }
        history = sample
    }

    // MARK: Demo inspector

    /// Fills the inspector with simulated packets that run through the real decoder.
    func startDemoInspector(startedAt: Date, currentMinute: Int, raw: @escaping (Int) -> Int) {
        demoRaw = raw
        var demo = LibreSensorRecord(uid: LibreSimulator.demoUID, patchInfo: LibreSimulator.demoPatchInfo,
                                     ageMinutes: currentMinute, maxLifeMinutes: 0, now: Date())
        demo.activatedAt = startedAt
        demoRecord = demo
        packets.removeAll { $0.isSimulated }
        nfcRecords.removeAll { $0.isSimulated }

        if let encrypted = try? LibreSimulator.fram(ageMinutes: currentMinute, raw: raw) {
            let decrypted = try? Libre2Crypto.decryptFRAM(uid: demo.uid, patchInfo: demo.patchInfo, data: encrypted)
            appendNFC(NFCRecord(date: demo.timestamp(forMinute: currentMinute), uid: demo.uid, patchInfo: demo.patchInfo,
                                encrypted: encrypted, decrypted: decrypted, fram: decrypted.flatMap { try? LibreFRAM(decrypted: $0) },
                                streamingResponse: nil, error: nil, isSimulated: true))
        }
        for minute in max(0, currentMinute - 15)..<currentMinute {
            simulatePacket(ageMinutes: minute)
        }
    }

    func simulatePacket(ageMinutes: Int) {
        guard let demo = demoRecord, let raw = demoRaw,
              let encrypted = try? LibreSimulator.blePacket(ageMinutes: ageMinutes, raw: raw) else { return }
        do {
            let decrypted = try Libre2Crypto.decryptBLE(uid: demo.uid, packet: encrypted)
            let parsed = try LibreBLEPacket(decrypted: decrypted)
            let readings = demo.glucoseReadings(from: parsed.trend + parsed.history, liveSource: .simulated)
            appendPacket(PacketRecord(date: demo.timestamp(forMinute: ageMinutes), encrypted: encrypted, decrypted: decrypted,
                                      packet: parsed, readings: readings, error: nil, isSimulated: true))
        } catch {
            appendPacket(PacketRecord(date: demo.timestamp(forMinute: ageMinutes), encrypted: encrypted, decrypted: nil,
                                      packet: nil, readings: [], error: "\(error)", isSimulated: true))
        }
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
        let decrypted: [UInt8]
        let parsed: LibreBLEPacket
        do {
            decrypted = try Libre2Crypto.decryptBLE(uid: record.uid, packet: packet)
            parsed = try LibreBLEPacket(decrypted: decrypted)
        } catch {
            appendPacket(PacketRecord(date: Date(), encrypted: packet, decrypted: nil, packet: nil, readings: [],
                                      error: "\(error)", isSimulated: false))
            if record.peripheralIdentifier == id {
                log("Corrupt packet ignored: \(error)")
            } else {
                log("Packet from another device rejected")
                ble.reject(id)
            }
            return
        }

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

        let readings = record.glucoseReadings(from: parsed.history, liveSource: .bluetooth)
            + record.glucoseReadings(from: parsed.trend, liveSource: .bluetooth)
        appendPacket(PacketRecord(date: Date(), encrypted: packet, decrypted: decrypted, packet: parsed, readings: readings,
                                  error: nil, isSimulated: false))

        if parsed.ageMinutes >= record.maxLifeMinutes {
            status = .ended
            history.markEnded(id: record.uid.hexString, at: Date(), reason: .expired)
            saveHistory()
            ble.stop()
            onEvent?(.sensorEnded)
            return
        }
        status = parsed.ageMinutes < LibreSensorRecord.warmUpMinutes ? .warmingUp(until: record.warmUpEndsAt) : .connected
        onReadings?(readings, true)
    }

    // MARK: Helpers

    private func appendPacket(_ packet: PacketRecord) {
        packets.insert(packet, at: 0)
        if packets.count > Self.packetLogLimit { packets.removeLast(packets.count - Self.packetLogLimit) }
    }

    private func appendNFC(_ record: NFCRecord) {
        nfcRecords.insert(record, at: 0)
        if nfcRecords.count > 20 { nfcRecords.removeLast(nfcRecords.count - 20) }
    }

    private func save() {
        guard let record else { return }
        try? stores.sensor.save(record)
    }

    private func saveHistory() {
        try? stores.sensorHistory.save(history)
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
