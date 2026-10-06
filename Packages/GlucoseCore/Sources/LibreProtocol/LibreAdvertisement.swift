import Foundation

/// What a Libre 2 Bluetooth advertisement says about which sensor sent it.
///
/// Older Libre 2 sensors advertise "ABBOTT" followed by their serial number. Newer Libre 2 Plus EU
/// sensors advertise their MAC address as 12 hexadecimal digits (per DiaBLE). Telling them apart
/// keeps the app from locking onto another Libre nearby, such as the previous sensor still on
/// your arm or a family member's.
public enum LibreAdvertisement {
    /// False only when the advertised name clearly belongs to another sensor. An unknown name
    /// format, or a missing serial or address to compare with, never hides the paired sensor.
    public static func mayBelong(name: String, serial: String?, address: [UInt8]?) -> Bool {
        var body = name.uppercased()
        if body.hasPrefix("ABBOTT") { body.removeFirst("ABBOTT".count) }
        if let serial, !serial.isEmpty, body.count == serial.count,
           body.first?.isNumber == true, body.allSatisfy({ $0.isLetter || $0.isNumber }) {
            return body == serial.uppercased()
        }
        if let address, address.count == 6, body.count == 12, body.allSatisfy(\.isHexDigit) {
            return body == address.map { String(format: "%02X", $0) }.joined()
        }
        return true
    }
}
