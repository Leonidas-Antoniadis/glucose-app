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
        /// An NFC scan of the paired sensor worked.
        case scanned
        case bluetoothOff
        case sensorEnded
        /// The sensor was forgotten: its scheduled notifications no longer apply.
        case forgotten
        case error(String)
        /// The sensor's start time moved by `interval` (the phone clock changed or drifted):
        /// its readings must be re-dated before new ones arrive.
        case timelineShifted(serial: String, activatedAt: Date, interval: TimeInterval)
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
        var uid: [UInt8] = []
        var patchInfo: [UInt8] = []
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
    /// Bluetooth link quality and outages, for the Sensor screen's signal report.
    private(set) var signal = SignalStats()
    @ObservationIgnored private var signalSavedAt = Date.distantPast
    /// The link delivered a packet since it last connected.
    @ObservationIgnored private var linkDelivered = false
    /// A link that had delivered dropped; the next connection is a reconnect.
    @ObservationIgnored private var pendingReconnect = false
    /// A made-up sensor used in demo mode, so the inspector shows realistic bytes.
    private(set) var demoRecord: LibreSensorRecord?
    var allowUnverifiedTypes = false
    /// Packets and NFC reads kept on the phone (by you, or failed pairings).
    private(set) var saved: [SavedCapture] = []
    /// Keep the next Bluetooth packet that arrives.
    var savesNextPacket = false
    /// Keep the next NFC read.
    var savesNextNFC = false
    /// Also append every packet to the capture log file.
    var recordAllRawData = false

    @ObservationIgnored var onReadings: (@MainActor ([GlucoseReading], Bool) -> Void)?
    @ObservationIgnored var onEvent: (@MainActor (Event) -> Void)?
    @ObservationIgnored private let nfc = LibreNFCReader()
    @ObservationIgnored private let ble = LibreBLE()
    @ObservationIgnored private let stores: AppStores
    @ObservationIgnored private var running = false
    @ObservationIgnored private var demoRaw: ((Int) -> Int)?
    @ObservationIgnored private var expiryTimer: Timer?
    /// Packets that didn't decrypt, per peripheral not yet confirmed as ours.
    @ObservationIgnored private var unconfirmedFailures: [UUID: Int] = [:]
    static let unconfirmedFailureLimit = 3
    @ObservationIgnored private let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    init(stores: AppStores) {
        self.stores = stores
        record = stores.sensor.load()
        history = stores.sensorHistory.load() ?? SensorHistory()
        saved = stores.savedCaptures.load() ?? []
        signal = stores.signalStats.load() ?? SignalStats()
        signal.prune(now: Date())
        // An outage open when the app was killed ends at the last save; the rest is the app
        // not running.
        signal.closeOutageLeftOpen()
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
        if endIfExpired(notify: false) { return }
        signal.resumeCounting(at: Date())
        status = ble.isPoweredOff ? .bluetoothOff : .searching
        ble.knownPeripheralID = record.peripheralIdentifier
        ble.expectedSerial = record.serial
        ble.expectedAddress = record.bluetoothAddress
        ble.start()
        scheduleExpiryCheck()
    }

    /// `pausing`: the app stops the connection to save battery while it's closed, which the
    /// signal report lists as the reason for the gap.
    func stop(pausing: Bool = false) {
        if running, record != nil, status != .ended {
            if pausing {
                signal.linkLost(at: Date(), reason: .appPaused)
            } else {
                // Not reading a sensor (the demo): no packets are expected, and it's no gap.
                signal.pauseCounting(at: Date())
            }
        }
        running = false
        expiryTimer?.invalidate()
        ble.stop()
        saveSignal(force: true)
    }

    // MARK: Signal report

    /// Saves the signal counters: right away when asked, otherwise at most every 10 minutes.
    func saveSignal(force: Bool) {
        guard force || Date().timeIntervalSince(signalSavedAt) > 600 else { return }
        signalSavedAt = Date()
        signal.prune(now: Date())
        signal.savedAt = Date()
        try? stores.signalStats.save(signal)
    }

    /// Starts the counting over, for "Delete all data".
    func resetSignalStats() {
        signal = SignalStats()
        stores.signalStats.delete()
    }

    /// Call when the app comes to the foreground: catches a sensor that reached the end of its
    /// life while the app was suspended.
    func appDidBecomeActive() {
        guard running else { return }
        endIfExpired(notify: false)
    }

    /// Ends the sensor once its wear time is over, also when its last packet came just before
    /// the end and no packet will ever report it. Returns true if the sensor has ended.
    @discardableResult
    private func endIfExpired(notify: Bool) -> Bool {
        guard let record, Date() >= record.expiresAt else { return false }
        guard status != .ended else { return true }
        status = .ended
        // A link that dropped just before the end won't come back: that's not an outage.
        signal.endOpenOutage(at: min(Date(), record.expiresAt))
        history.markEnded(id: record.uid.hexString, at: min(Date(), record.expiresAt), reason: .expired)
        saveHistory()
        expiryTimer?.invalidate()
        ble.stop()
        if notify { onEvent?(.sensorEnded) }
        return true
    }

    private func scheduleExpiryCheck() {
        expiryTimer?.invalidate()
        guard running, let record else { return }
        let interval = record.expiresAt.timeIntervalSinceNow + 1
        guard interval > 0 else { return }
        expiryTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.endIfExpired(notify: true) }
        }
    }

    func forget() {
        if let record {
            history.markEnded(id: record.uid.hexString, at: Date(), reason: Date() >= record.expiresAt ? .expired : .removedEarly)
            saveHistory()
        }
        // Until the next sensor is paired there's nothing to read.
        signal.pauseCounting(at: Date())
        saveSignal(force: true)
        ble.resetForNewSensor()
        expiryTimer?.invalidate()
        unconfirmedFailures = [:]
        record = nil
        stores.sensor.delete()
        status = .notPaired
        lastPacketAt = nil
        lastRaw = nil
        log("Sensor forgotten")
        onEvent?(.forgotten)
    }

    /// Restores a sensor record from a backup (the sensor itself still needs to be in range).
    func restore(_ restored: LibreSensorRecord) {
        record = restored
        save()
        ble.resetForNewSensor()
        unconfirmedFailures = [:]
        ble.knownPeripheralID = restored.peripheralIdentifier
        log("Sensor restored from backup")
    }

    // MARK: NFC

    /// Pairs with a running sensor: reads it, enables Bluetooth streaming, imports its history.
    func pair() async {
        await connect(.pair)
    }

    /// Starts a new sensor (it can't be stopped again), then pairs it.
    func startNewSensor() async {
        await connect(.start)
    }

    private func connect(_ mode: LibreNFCReader.Mode) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let scan = try await nfc.scan(mode, allowUnverified: allowUnverifiedTypes)
            if let response = scan.activationResponse {
                capture("NFC activate", response)
                log("Started new sensor (response \(response.hexString))")
            }
            if let response = scan.streamingResponse { capture("NFC enable", response) }
            let fram = try decodeAndLog(scan)
            guard fram.state == .active || fram.state == .warmingUp else {
                throw LibreProtocolError.unsupportedSensor("sensor state is \(fram.state.description)")
            }
            // Re-pairing the same sensor (e.g. after LibreLink took it back) keeps its calibration.
            var newRecord = LibreSensorRecord.paired(uid: scan.uid, patchInfo: scan.patchInfo, ageMinutes: fram.ageMinutes,
                                                     maxLifeMinutes: fram.maxLifeMinutes, now: Date(), previous: record)
            newRecord.bluetoothAddress = LibreSensorRecord.bluetoothAddress(fromEnableResponse: scan.streamingResponse)
            // A different sensor: never connect to the old one's peripheral again (it may still be advertising).
            let previousPeripheral = record.flatMap { $0.uid == newRecord.uid ? nil : $0.peripheralIdentifier }
            record = newRecord
            save()
            history.record(SensorHistoryEntry(
                id: newRecord.uid.hexString, sensorType: newRecord.type.displayName, computedSerial: newRecord.serial,
                uidHex: newRecord.uid.hexString, patchInfoHex: newRecord.patchInfo.hexString,
                startedAt: newRecord.activatedAt, pairedAt: Date(), expectedEnd: newRecord.expiresAt,
                note: scan.activationResponse != nil ? "Started in this app" : ""
            ), at: Date(), reopen: true) // the sensor is running, even if it was forgotten earlier
            saveHistory()
            log("Paired \(newRecord.type.displayName), serial \(newRecord.serial), age \(fram.ageMinutes) min")
            importFRAM(fram, record: newRecord)

            ble.resetForNewSensor(avoiding: previousPeripheral)
            unconfirmedFailures = [:]
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
            let scan = try await nfc.scan(.read, allowUnverified: allowUnverifiedTypes)
            let fram = try decodeAndLog(scan)
            guard scan.uid == record.uid else { throw NFCReadError.differentSensor }
            if fram.state == .failure {
                history.markEnded(id: record.uid.hexString, at: Date(), reason: .failed)
                saveHistory()
            }
            importFRAM(fram, record: record)
            log("NFC scan imported \(fram.trend.count + fram.history.count) values")
            onEvent?(.scanned)
        } catch NFCReadError.cancelled {
            log("NFC scan cancelled")
        } catch {
            logFailedRead(error)
            // A failed scan says nothing about the Bluetooth link, so the status stays as it is.
            fail(error, updatesStatus: false)
        }
    }

    /// Decodes a scan and adds it to the NFC log, also when decoding fails.
    private func decodeAndLog(_ scan: LibreNFCReader.ScanResult) throws -> LibreFRAM {
        do {
            let decrypted = try Libre2Crypto.decryptFRAM(uid: scan.uid, patchInfo: scan.patchInfo, data: scan.fram)
            let fram = try LibreFRAM(decrypted: decrypted)
            _ = nfc.takeLastRead()
            appendNFC(NFCRecord(date: Date(), uid: scan.uid, patchInfo: scan.patchInfo, encrypted: scan.fram, decrypted: decrypted,
                                fram: fram, streamingResponse: scan.streamingResponse, error: nil, isSimulated: false))
            return fram
        } catch {
            _ = nfc.takeLastRead()
            appendNFC(NFCRecord(date: Date(), uid: scan.uid, patchInfo: scan.patchInfo, encrypted: scan.fram, decrypted: nil,
                                fram: nil, streamingResponse: scan.streamingResponse, error: "\(error)", isSimulated: false))
            keep(SavedCapture(date: Date(), kind: .nfc, uid: scan.uid, patchInfo: scan.patchInfo, bytes: scan.fram,
                              enableResponse: scan.streamingResponse, isSimulated: false, reason: "Decoding failed: \(error)"))
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
        // Failed reads are always kept: they're what's needed to fix decoding for this sensor.
        keep(SavedCapture(date: Date(), kind: .nfc, uid: raw.uid, patchInfo: raw.patchInfo, bytes: raw.fram,
                          enableResponse: nil, isSimulated: false, reason: "Read failed: \(message)"))
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

    /// Calibrates against a fingerstick. `raw` is the sensor's raw value at the fingerstick's time
    /// (see `AppModel.addFingerstick`).
    @discardableResult
    func calibrate(referenceMgdL: Double, raw: Double, at date: Date) -> CalibrationOutcome? {
        guard var record else { return nil }
        let outcome = record.addCalibration(referenceMgdL: referenceMgdL, raw: raw, date: date)
        self.record = record
        save()
        switch outcome {
        case .applied:
            log(String(format: "Calibrated: slope %.4f, intercept %.1f, %ld points",
                       record.calibration.slope, record.calibration.intercept, record.calibration.pointCount))
        case .warmingUp:
            log("Calibration refused: sensor warming up")
        case .needsConfirmation(let sensorMgdL):
            log(String(format: "Fingerstick %.0f far from sensor %.0f: waiting for a second one", referenceMgdL, sensorMgdL))
        case .tooOld:
            log("Calibration refused: more than 96 hours before the newest one")
        }
        return outcome
    }

    /// Removes a deleted fingerstick's calibration point (matched by id, or for fingersticks saved
    /// before ids were kept, by time and value). Returns true if the calibration changed.
    func removeCalibration(pointID: UUID?, date: Date, mgdL: Double) -> Bool {
        guard var record else { return false }
        let match = record.calibrationPoints.first { point in
            point.id == pointID || (abs(point.date.timeIntervalSince(date)) < 1 && point.referenceMgdL == mgdL)
        }
        guard let match, record.removeCalibration(id: match.id) else { return false }
        self.record = record
        save()
        log("Calibration point removed (fingerstick deleted), \(record.calibration.pointCount) left")
        return true
    }

    // MARK: Sensor history

    func updateHistory(_ entry: SensorHistoryEntry) {
        history.update(entry)
        saveHistory()
    }

    /// Adds a sensor used outside this app (e.g. with LibreLink), so its details are on file too.
    func addManualSensor(_ entry: SensorHistoryEntry) {
        history.addManual(entry, currentID: record?.uid.hexString)
        saveHistory()
    }

    func removeHistory(id: String) {
        history.remove(id: id)
        saveHistory()
    }

    /// An example signal report for CI screenshots: a good day with one 30-minute drop at night.
    /// Kept in memory only.
    func seedSampleSignal(now: Date) {
        var sample = SignalStats()
        let start = now.addingTimeInterval(-24 * 3600)
        let dropStart = now.addingTimeInterval(-10 * 3600)
        var minute = start
        while minute < now {
            let inDrop = minute >= dropStart && minute < dropStart.addingTimeInterval(1800)
            if !inDrop {
                sample.recordPacket(at: minute, unusable: minute.timeIntervalSince(start) == 3 * 3600)
                sample.recordRSSI(-66 - 6 * sin(minute.timeIntervalSince1970 / 5000), at: minute)
            }
            minute.addTimeInterval(60)
        }
        sample.linkLost(at: dropStart, reason: .linkLost)
        sample.recordPacket(at: dropStart.addingTimeInterval(1800), unusable: false)
        sample.recordReconnect(at: dropStart.addingTimeInterval(1790))
        sample.recordReconnect(at: now.addingTimeInterval(-5 * 3600))
        sample.recordCorruptPacket(at: now.addingTimeInterval(-3 * 3600))
        signal = sample
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
        // The demo sensor never ends (at 60x it ages a day every 24 minutes). With a real
        // lifetime the decoder would drop every packet past day 14 as "after the sensor ended".
        var demo = LibreSensorRecord(uid: LibreSimulator.demoUID, patchInfo: LibreSimulator.demoPatchInfo,
                                     ageMinutes: currentMinute, maxLifeMinutes: currentMinute + 365 * 1440, now: Date())
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
        case .poweredOn:
            // Bluetooth is back: show what the sensor is doing instead of "Bluetooth is off".
            guard status == .bluetoothOff else { break }
            if record == nil {
                status = .notPaired
            } else if !endIfExpired(notify: false), running {
                status = .searching
            }
        case .poweredOff:
            // An ended or missing sensor stays that way; Bluetooth doesn't matter then.
            guard status != .ended, status != .notPaired else { break }
            status = .bluetoothOff
            if running, record != nil {
                signal.linkLost(at: Date(), reason: .bluetoothOff)
                saveSignal(force: true)
                onEvent?(.bluetoothOff)
            }
        case .unauthorized:
            status = .error("Bluetooth permission is off. Allow it in Settings.")
        case .scanning:
            status = .searching
            log("Scanning")
        case .connecting:
            if status != .connected { status = .connecting }
        case .connected(let id):
            log("Connected to \(id.uuidString.prefix(8))")
            // A reconnect is a link that delivered packets coming back, not the first connection
            // (or one to another sensor while searching).
            if pendingReconnect {
                pendingReconnect = false
                signal.recordReconnect(at: Date())
            }
        case .disconnected:
            // A sensor at the end of its life stops sending and drops the link.
            if endIfExpired(notify: true) { break }
            log("Disconnected, waiting to reconnect")
            if status == .connected { status = .connecting }
            if linkDelivered {
                linkDelivered = false
                pendingReconnect = true
            }
            if running, record != nil {
                signal.linkLost(at: Date(), reason: .linkLost)
                // Saved now: if iOS kills the app during the outage, it still shows.
                saveSignal(force: true)
            }
        case .packet(let packet, let id):
            handlePacket(packet, from: id)
        case .rssi(let value):
            // Only right after a packet from our sensor decoded, not another device's.
            if let last = lastPacketAt, Date().timeIntervalSince(last) < 5 {
                signal.recordRSSI(Double(value), at: Date())
            }
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
                signal.recordCorruptPacket(at: Date())
            } else {
                // One corrupt packet from our own sensor shouldn't lock it out: allow a few.
                let failures = (unconfirmedFailures[id] ?? 0) + 1
                unconfirmedFailures[id] = failures
                if failures >= Self.unconfirmedFailureLimit {
                    unconfirmedFailures[id] = nil
                    log("Packets from \(id.uuidString.prefix(8)) don't decode: another device, looking elsewhere")
                    ble.reject(id, for: 10 * 60)
                } else {
                    log("Packet didn't decode (\(failures) of \(Self.unconfirmedFailureLimit))")
                }
            }
            return
        }

        if record.peripheralIdentifier != id {
            record.peripheralIdentifier = id
            unconfirmedFailures = [:]
            ble.confirm(id)
            log("Sensor confirmed")
        }
        // Keep the timeline anchored to the sensor's own clock. If the phone clock changed or
        // drifted, the readings so far are re-dated too, or new ones would sort before them.
        if abs(record.ageMinutes(at: Date()) - parsed.ageMinutes) > 2 {
            let aligned = (Date().timeIntervalSince1970 / 60).rounded(.down) * 60
            let oldStart = record.activatedAt
            record.activatedAt = Date(timeIntervalSince1970: aligned - Double(parsed.ageMinutes) * 60)
            let interval = record.activatedAt.timeIntervalSince(oldStart)
            log(String(format: "Sensor clock re-anchored by %+.0f min", interval / 60))
            onEvent?(.timelineShifted(serial: record.serial, activatedAt: record.activatedAt, interval: interval))
            self.record = record
            scheduleExpiryCheck()
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
        // This minute gave no reading although the sensor is past warm-up: the parser drops a
        // value of 0 (the sensor's error), so the slot is missing or produced nothing.
        let unusable = parsed.ageMinutes >= LibreSensorRecord.warmUpMinutes
            && !readings.contains { $0.minuteIndex == parsed.ageMinutes }
        linkDelivered = true
        signal.recordPacket(at: Date(), unusable: unusable)
        saveSignal(force: false)

        if parsed.ageMinutes >= record.maxLifeMinutes {
            signal.endOpenOutage(at: Date())
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

    private func appendPacket(_ incoming: PacketRecord) {
        var packet = incoming
        if let source = packet.isSimulated ? demoRecord : record {
            packet.uid = source.uid
            packet.patchInfo = source.patchInfo
        }
        packets.insert(packet, at: 0)
        if packets.count > Self.packetLogLimit { packets.removeLast(packets.count - Self.packetLogLimit) }
        if savesNextPacket {
            savesNextPacket = false
            keep(packet)
        }
    }

    private func appendNFC(_ read: NFCRecord) {
        nfcRecords.insert(read, at: 0)
        if nfcRecords.count > 20 { nfcRecords.removeLast(nfcRecords.count - 20) }
        if savesNextNFC {
            savesNextNFC = false
            keep(read)
        }
    }

    // MARK: Saved captures

    func keep(_ packet: PacketRecord, reason: String = "Saved by you") {
        keep(SavedCapture(date: packet.date, kind: .bluetooth, uid: packet.uid, patchInfo: packet.patchInfo,
                          bytes: packet.encrypted, enableResponse: nil, isSimulated: packet.isSimulated, reason: reason))
    }

    func keep(_ read: NFCRecord, reason: String = "Saved by you") {
        keep(SavedCapture(date: read.date, kind: .nfc, uid: read.uid, patchInfo: read.patchInfo, bytes: read.encrypted,
                          enableResponse: read.streamingResponse, isSimulated: read.isSimulated, reason: reason))
    }

    private func keep(_ capture: SavedCapture) {
        // The same bytes saved twice are kept once.
        guard !saved.contains(where: { $0.bytes == capture.bytes && $0.date == capture.date }) else { return }
        saved.insert(capture, at: 0)
        try? stores.savedCaptures.save(saved)
        log("Saved \(capture.title.lowercased())")
    }

    func isKept(bytes: [UInt8], date: Date) -> Bool {
        saved.contains { $0.bytes == bytes && $0.date == date }
    }

    func deleteSaved(olderThan cutoff: Date) {
        guard saved.contains(where: { $0.date < cutoff }) else { return }
        saved.removeAll { $0.date < cutoff }
        try? stores.savedCaptures.save(saved)
    }

    func deleteSaved(_ ids: Set<UUID>) {
        saved.removeAll { ids.contains($0.id) }
        try? stores.savedCaptures.save(saved)
    }

    /// Empties the kept captures and the recent packets and scans, for "Delete all data". Without
    /// this, keeping one more capture would write the old ones back to disk.
    func clearCaptures() {
        saved = []
        packets.removeAll { !$0.isSimulated }
        nfcRecords.removeAll { !$0.isSimulated }
        stores.savedCaptures.delete()
    }

    /// Writes the saved captures to a text file for sharing.
    func exportSaved() -> URL? {
        let url = AppStores.exportsDirectory.appendingPathComponent("Libre captures.txt")
        do {
            try SavedCapture.exportText(saved).write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    /// Decodes a saved packet again, for the detail view.
    func packetRecord(from capture: SavedCapture) -> PacketRecord {
        let decrypted = try? Libre2Crypto.decryptBLE(uid: capture.uid, packet: capture.bytes)
        let parsed = decrypted.flatMap { try? LibreBLEPacket(decrypted: $0) }
        var readings: [GlucoseReading] = []
        if let parsed {
            var decoder = LibreSensorRecord(uid: capture.uid, patchInfo: capture.patchInfo, ageMinutes: parsed.ageMinutes,
                                            maxLifeMinutes: 0, now: capture.date)
            if let record, record.uid == capture.uid { decoder.calibration = record.calibration }
            readings = decoder.glucoseReadings(from: parsed.trend + parsed.history, liveSource: .bluetooth)
        }
        var packet = PacketRecord(date: capture.date, encrypted: capture.bytes, decrypted: decrypted, packet: parsed,
                                  readings: readings, error: parsed == nil ? "Doesn't decode with this sensor ID" : nil,
                                  isSimulated: capture.isSimulated)
        packet.uid = capture.uid
        packet.patchInfo = capture.patchInfo
        return packet
    }

    /// Decodes a saved NFC read again, for the detail view.
    func nfcRecord(from capture: SavedCapture) -> NFCRecord {
        let decrypted = try? Libre2Crypto.decryptFRAM(uid: capture.uid, patchInfo: capture.patchInfo, data: capture.bytes)
        let fram = decrypted.flatMap { try? LibreFRAM(decrypted: $0) }
        return NFCRecord(date: capture.date, uid: capture.uid, patchInfo: capture.patchInfo, encrypted: capture.bytes,
                         decrypted: decrypted, fram: fram, streamingResponse: capture.enableResponse,
                         error: fram == nil ? capture.reason : nil, isSimulated: capture.isSimulated)
    }

    private func save() {
        guard let record else { return }
        try? stores.sensor.save(record)
    }

    private func saveHistory() {
        try? stores.sensorHistory.save(history)
    }

    private func fail(_ error: Error, updatesStatus: Bool = true) {
        let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        if updatesStatus { status = .error(message) }
        log("Error: \(message)")
        onEvent?(.error(message))
    }

    private func log(_ message: String) {
        debugLog.insert("\(timeFormatter.string(from: Date())) \(message)", at: 0)
        if debugLog.count > 200 { debugLog.removeLast(debugLog.count - 200) }
    }

    private func capture(_ kind: String, _ bytes: [UInt8]) {
        guard recordAllRawData else { return }
        stores.appendCapture("\(ISO8601DateFormatter().string(from: Date())) | \(kind) | \(bytes.hexString)")
    }
}
