import Foundation
import CoreBluetooth

/// Bluetooth link to a Libre 2 sensor.
///
/// Keeps a pending connection open at all times (iOS reconnects whenever the sensor is in range,
/// even in the background) and restores state after iOS relaunches the app. Characteristics
/// are found by their properties rather than hard-coded ids: the writable one receives the
/// unlock payload, the notifying ones deliver 46-byte packets in chunks.
final class LibreBLE: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    enum Event {
        case poweredOff
        case unauthorized
        case scanning
        case connecting(UUID)
        case connected(UUID)
        case disconnected(UUID)
        case packet([UInt8], UUID)
        case log(String)
    }

    static let serviceUUID = CBUUID(string: "FDE3")
    static let restoreIdentifier = "glucose.libre.central"
    static let packetSize = 46

    /// Called on the main queue.
    var onEvent: ((Event) -> Void)?
    /// Returns the next unlock payload (advances the sensor record's counter).
    var unlockPayload: (() -> [UInt8]?)?
    var knownPeripheralID: UUID?

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var buffer: [UInt8] = []
    private var lastChunkAt = Date.distantPast
    private var rejected = Set<UUID>()
    private var wantsConnection = false
    private var unlockSent = false

    var isPoweredOn: Bool { central?.state == .poweredOn }

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
    }

    /// Forget everything about the previous sensor's peripheral.
    func resetForNewSensor() {
        stop()
        rejected.removeAll()
        knownPeripheralID = nil
    }

    /// A packet from this peripheral decrypted correctly: it is our sensor.
    func confirm(_ id: UUID) {
        knownPeripheralID = id
        central?.stopScan()
    }

    /// Packets from this peripheral don't decrypt: it's another sensor. Look elsewhere.
    func reject(_ id: UUID) {
        rejected.insert(id)
        if let peripheral, peripheral.identifier == id {
            central?.cancelPeripheralConnection(peripheral)
            self.peripheral = nil
        }
        if knownPeripheralID == id { knownPeripheralID = nil }
        scan()
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

    private func scan() {
        guard wantsConnection, let central, central.state == .poweredOn else { return }
        onEvent?(.scanning)
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    private func connect(_ target: CBPeripheral) {
        peripheral = target
        target.delegate = self
        buffer = []
        unlockSent = false
        writeCharacteristic = nil
        onEvent?(.connecting(target.identifier))
        central?.connect(target, options: nil)
    }

    // MARK: CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn: connectOrScan()
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
            onEvent?(.log("Restored Bluetooth state"))
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover found: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard !rejected.contains(found.identifier) else { return }
        let name = found.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? ""
        let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        guard name.uppercased().hasPrefix("ABBOTT") || services.contains(Self.serviceUUID) else { return }
        onEvent?(.log("Found \(name.isEmpty ? "Libre sensor" : name), signal \(RSSI) dBm"))
        central.stopScan()
        connect(found)
    }

    func centralManager(_ central: CBCentralManager, didConnect connected: CBPeripheral) {
        onEvent?(.connected(connected.identifier))
        connected.discoverServices([Self.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect failed: CBPeripheral, error: Error?) {
        onEvent?(.log("Connection failed: \(error?.localizedDescription ?? "unknown error")"))
        reconnect(failed)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral lost: CBPeripheral, error: Error?) {
        onEvent?(.disconnected(lost.identifier))
        reconnect(lost)
    }

    /// A pending connect never times out, so iOS reconnects as soon as the sensor is back in range.
    private func reconnect(_ target: CBPeripheral) {
        guard wantsConnection, !rejected.contains(target.identifier), peripheral?.identifier == target.identifier else { return }
        connect(target)
    }

    // MARK: CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else {
            onEvent?(.log("Libre service not found on this device"))
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
        for characteristic in service.characteristics ?? []
        where characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate) {
            peripheral.setNotifyValue(true, for: characteristic)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
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
        if let error { onEvent?(.log("Unlock write failed: \(error.localizedDescription)")) }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value, !data.isEmpty else { return }
        let now = Date()
        if now.timeIntervalSince(lastChunkAt) > 5 { buffer = [] }
        lastChunkAt = now
        buffer += data
        if buffer.count >= Self.packetSize {
            let packet = Array(buffer.prefix(Self.packetSize))
            buffer = []
            onEvent?(.packet(packet, peripheral.identifier))
        }
    }
}
