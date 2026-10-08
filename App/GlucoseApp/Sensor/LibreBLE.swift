import Foundation
import CoreBluetooth
import UIKit
import LibreProtocol

/// Bluetooth link to a Libre 2 sensor.
///
/// Keeps a pending connection open at all times (iOS reconnects whenever the sensor is in range,
/// even in the background) and restores state after iOS relaunches the app. Characteristics
/// are found by their properties rather than hard-coded ids: the writable one receives the
/// unlock payload, the notifying ones deliver 46-byte packets in chunks.
///
/// Until a packet decrypts, a peripheral is only a candidate: other Libre sensors nearby (the
/// previous one still on your arm, a family member's) advertise too. Candidates whose name
/// belongs to another sensor are passed over, and one that sends nothing for a few minutes is
/// set aside for a while so the scan can find the right one.
final class LibreBLE: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    enum Event {
        case poweredOn
        case poweredOff
        case unauthorized
        case scanning
        case connecting(UUID)
        case connected(UUID)
        case disconnected(UUID)
        case packet([UInt8], UUID)
        /// Signal strength of the connected sensor, in dBm.
        case rssi(Int)
        case log(String)
    }

    static let serviceUUID = CBUUID(string: "FDE3")
    static let restoreIdentifier = "glucose.libre.central"
    static let packetSize = 46
    /// How long a candidate may stay connected without sending a packet that decrypts.
    static let candidateTimeout: TimeInterval = 150
    /// How long a set-aside candidate is passed over before it is tried again.
    static let retryAfter: TimeInterval = 5 * 60
    /// How long the paired sensor may stay connected without sending anything (it sends once a
    /// minute) before the link is dropped and made again with a fresh unlock.
    static let silentLinkTimeout: TimeInterval = 4 * 60
    /// The shortest time between two such restarts, so a link that keeps failing doesn't spin.
    static let restartInterval: TimeInterval = 60

    /// Called on the main queue.
    var onEvent: ((Event) -> Void)?
    /// Returns the next unlock payload (advances the sensor record's counter).
    var unlockPayload: (() -> [UInt8]?)?
    var knownPeripheralID: UUID?
    /// What the paired sensor advertises: "ABBOTT" + serial, or its MAC address on newer sensors.
    var expectedSerial: String?
    var expectedAddress: [UInt8]?

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var buffer: [UInt8] = []
    private var lastChunkAt = Date.distantPast
    /// Peripherals passed over until the given time (`distantFuture` for this pairing).
    private var skippedUntil: [UUID: Date] = [:]
    private var candidateID: UUID?
    private var candidateTimer: Timer?
    private var rescanTimer: Timer?
    private var silenceTimer: Timer?
    private var lastRestartAt = Date.distantPast
    private var wantsConnection = false
    private var unlockSent = false

    var isPoweredOn: Bool { central?.state == .poweredOn }
    var isPoweredOff: Bool { central?.state == .poweredOff }

    override init() {
        super.init()
        // iOS only reports scan results in the background for scans that name a service,
        // so the scan is restarted with the right filter whenever the app changes state.
        NotificationCenter.default.addObserver(self, selector: #selector(appStateChanged),
                                               name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appStateChanged),
                                               name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    func start() {
        wantsConnection = true
        if central == nil {
            central = CBCentralManager(delegate: self, queue: nil, options: [
                CBCentralManagerOptionRestoreIdentifierKey: Self.restoreIdentifier,
                CBCentralManagerOptionShowPowerAlertKey: true,
            ])
        } else {
            connectOrScan()
        }
    }

    func stop() {
        wantsConnection = false
        central?.stopScan()
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
        peripheral = nil
        clearCandidate()
        rescanTimer?.invalidate()
        silenceTimer?.invalidate()
    }

    /// Forget everything about the previous sensor's peripheral. `previous` (the old sensor's
    /// peripheral, when a different sensor was paired) is passed over from now on.
    func resetForNewSensor(avoiding previous: UUID? = nil) {
        stop()
        skippedUntil.removeAll()
        knownPeripheralID = nil
        if let previous { skippedUntil[previous] = .distantFuture }
    }

    /// A packet from this peripheral decrypted correctly: it is our sensor.
    func confirm(_ id: UUID) {
        knownPeripheralID = id
        skippedUntil[id] = nil
        if candidateID == id { clearCandidate() }
        central?.stopScan()
    }

    /// This peripheral isn't (or doesn't act like) our sensor. Pass it over for `duration` and look elsewhere.
    func reject(_ id: UUID, for duration: TimeInterval) {
        skippedUntil[id] = Date().addingTimeInterval(duration)
        if candidateID == id { clearCandidate() }
        if let peripheral, peripheral.identifier == id {
            central?.cancelPeripheralConnection(peripheral)
            self.peripheral = nil
        }
        if knownPeripheralID == id { knownPeripheralID = nil }
        scheduleRescan(after: duration)
        scan()
    }

    private func isSkipped(_ id: UUID) -> Bool {
        guard let until = skippedUntil[id] else { return false }
        if until > Date() { return true }
        skippedUntil[id] = nil
        return false
    }

    private func connectOrScan() {
        guard wantsConnection, let central, central.state == .poweredOn else { return }
        if let peripheral, peripheral.state == .connected || peripheral.state == .connecting { return }
        if let id = knownPeripheralID, let known = central.retrievePeripherals(withIdentifiers: [id]).first {
            connect(known)
        } else {
            scan()
        }
    }

    private var isInBackground: Bool {
        MainActor.assumeIsolated { UIApplication.shared.applicationState == .background }
    }

    private func scan() {
        guard wantsConnection, let central, central.state == .poweredOn else { return }
        onEvent?(.scanning)
        // In the foreground, scan for everything: older sensors are recognised by name. In the
        // background iOS returns nothing without a service filter.
        let services: [CBUUID]? = isInBackground ? [Self.serviceUUID] : nil
        central.scanForPeripherals(withServices: services, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    @objc private func appStateChanged() {
        guard let central, central.isScanning else { return }
        central.stopScan()
        scan()
    }

    /// Restarts the scan once set-aside candidates may be tried again (a running scan reports
    /// each peripheral only once).
    private func scheduleRescan(after duration: TimeInterval) {
        guard duration < 86_400 else { return }
        rescanTimer?.invalidate()
        rescanTimer = Timer.scheduledTimer(timeInterval: duration + 1, target: self, selector: #selector(rescanIfIdle),
                                           userInfo: nil, repeats: false)
    }

    @objc private func rescanIfIdle() {
        guard wantsConnection, let central, central.state == .poweredOn else { return }
        if let peripheral, peripheral.state == .connected || peripheral.state == .connecting { return }
        central.stopScan()
        scan()
    }

    private func connect(_ target: CBPeripheral) {
        peripheral = target
        target.delegate = self
        buffer = []
        unlockSent = false
        writeCharacteristic = nil
        if target.identifier != knownPeripheralID { watchCandidate(target.identifier) }
        onEvent?(.connecting(target.identifier))
        central?.connect(target, options: nil)
    }

    /// Starts the clock for a peripheral that hasn't sent a packet that decrypts yet.
    private func watchCandidate(_ id: UUID) {
        guard candidateID != id else { return }
        clearCandidate()
        candidateID = id
        candidateTimer = Timer.scheduledTimer(timeInterval: Self.candidateTimeout, target: self,
                                              selector: #selector(candidateTimedOut), userInfo: nil, repeats: false)
    }

    private func clearCandidate() {
        candidateTimer?.invalidate()
        candidateTimer = nil
        candidateID = nil
    }

    @objc private func candidateTimedOut() {
        guard let id = candidateID, id != knownPeripheralID else { return }
        onEvent?(.log("No data from \(id.uuidString.prefix(8)) in \(Int(Self.candidateTimeout / 60)) min, looking for another sensor"))
        reject(id, for: Self.retryAfter)
    }

    /// Starts (or restarts) the clock for a connected link that stops delivering.
    private func watchForSilence() {
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(timeInterval: Self.silentLinkTimeout, target: self,
                                            selector: #selector(linkWentSilent), userInfo: nil, repeats: false)
    }

    @objc private func linkWentSilent() {
        // Candidates have their own, shorter clock.
        guard let peripheral, peripheral.identifier == knownPeripheralID else { return }
        restartLink(peripheral, reason: "No data for \(Int(Self.silentLinkTimeout / 60)) min")
    }

    /// Drops a connection that can't deliver (setup failed, or the sensor went quiet while still
    /// connected). `didDisconnectPeripheral` then connects again and sends a fresh unlock.
    private func restartLink(_ target: CBPeripheral, reason: String) {
        guard wantsConnection, target.state == .connected else { return }
        guard Date().timeIntervalSince(lastRestartAt) >= Self.restartInterval else {
            onEvent?(.log("\(reason); restarted the link less than a minute ago, waiting"))
            watchForSilence()
            return
        }
        lastRestartAt = Date()
        onEvent?(.log("\(reason), reconnecting"))
        central?.cancelPeripheralConnection(target)
    }

    // MARK: CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            onEvent?(.poweredOn)
            connectOrScan()
        case .poweredOff: onEvent?(.poweredOff)
        case .unauthorized: onEvent?(.unauthorized)
        default: break
        }
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        if let restored = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral])?.first {
            peripheral = restored
            restored.delegate = self
            wantsConnection = true
            if restored.state == .connected { watchForSilence() }
            onEvent?(.log("Restored Bluetooth state"))
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover found: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard !isSkipped(found.identifier) else { return }
        let name = found.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? ""
        let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        guard name.uppercased().hasPrefix("ABBOTT") || services.contains(Self.serviceUUID) else { return }
        let label = name.isEmpty ? "Libre sensor" : name
        let serviceList = services.isEmpty ? "none" : services.map(\.uuidString).joined(separator: ", ")
        guard LibreAdvertisement.mayBelong(name: name, serial: expectedSerial, address: expectedAddress) else {
            onEvent?(.log("Passing over \(label): another sensor"))
            skippedUntil[found.identifier] = .distantFuture
            return
        }
        onEvent?(.log("Found \(label), signal \(RSSI) dBm, services \(serviceList)"))
        central.stopScan()
        connect(found)
    }

    func centralManager(_ central: CBCentralManager, didConnect connected: CBPeripheral) {
        onEvent?(.connected(connected.identifier))
        watchForSilence()
        connected.discoverServices([Self.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect failed: CBPeripheral, error: Error?) {
        onEvent?(.log("Connection failed: \(error?.localizedDescription ?? "unknown error")"))
        silenceTimer?.invalidate()
        reconnect(failed)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral lost: CBPeripheral, error: Error?) {
        onEvent?(.disconnected(lost.identifier))
        // Out of range is handled by the pending connection, not by the silence clock.
        silenceTimer?.invalidate()
        reconnect(lost)
    }

    /// A pending connect never times out, so iOS reconnects as soon as the sensor is back in range.
    private func reconnect(_ target: CBPeripheral) {
        guard wantsConnection, !isSkipped(target.identifier), peripheral?.identifier == target.identifier else { return }
        connect(target)
    }

    // MARK: CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else {
            let detail = error.map { ": \($0.localizedDescription)" } ?? ""
            if peripheral.identifier != knownPeripheralID {
                onEvent?(.log("Libre service not found on this device\(detail)"))
                reject(peripheral.identifier, for: Self.retryAfter)
            } else {
                // Our sensor has the service: the discovery failed, so try the connection again.
                restartLink(peripheral, reason: "Service discovery failed\(detail)")
            }
            return
        }
        peripheral.discoverCharacteristics(nil, for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for characteristic in service.characteristics ?? [] {
            if characteristic.properties.contains(.write) || characteristic.properties.contains(.writeWithoutResponse) {
                writeCharacteristic = characteristic
            }
        }
        guard writeCharacteristic != nil else {
            restartLink(peripheral, reason: "Characteristics not found\(error.map { ": \($0.localizedDescription)" } ?? "")")
            return
        }
        for characteristic in service.characteristics ?? []
        where characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate) {
            peripheral.setNotifyValue(true, for: characteristic)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            // Only logged: another characteristic may still deliver. If none does, the silence
            // clock restarts the link.
            onEvent?(.log("Subscribe failed: \(error.localizedDescription)"))
            return
        }
        guard characteristic.isNotifying, !unlockSent, let write = writeCharacteristic, let payload = unlockPayload?() else { return }
        unlockSent = true
        let type: CBCharacteristicWriteType = write.properties.contains(.write) ? .withResponse : .withoutResponse
        peripheral.writeValue(Data(payload), for: write, type: type)
        onEvent?(.log("Unlock sent"))
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error { restartLink(peripheral, reason: "Unlock write failed: \(error.localizedDescription)") }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value, !data.isEmpty else { return }
        watchForSilence()
        let now = Date()
        if now.timeIntervalSince(lastChunkAt) > 5 { buffer = [] }
        lastChunkAt = now
        buffer += data
        if buffer.count >= Self.packetSize {
            let packet = Array(buffer.prefix(Self.packetSize))
            buffer = []
            onEvent?(.packet(packet, peripheral.identifier))
            // Once a minute is plenty for the signal report.
            peripheral.readRSSI()
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        guard error == nil else { return }
        onEvent?(.rssi(RSSI.intValue))
    }
}
