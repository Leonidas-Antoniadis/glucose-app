import XCTest
@testable import LibreProtocol

final class LibreAdvertisementTests: XCTestCase {
    private let serial = "3MH001ABCDE"
    private let address: [UInt8] = [0xA4, 0xB1, 0xC2, 0xD3, 0xE4, 0xF5]

    func testOlderSensorsAreMatchedBySerial() {
        XCTAssertTrue(LibreAdvertisement.mayBelong(name: "ABBOTT3MH001ABCDE", serial: serial, address: nil))
        XCTAssertTrue(LibreAdvertisement.mayBelong(name: "abbott3mh001abcde", serial: serial, address: nil))
        XCTAssertFalse(LibreAdvertisement.mayBelong(name: "ABBOTT3MH009ZZZZZ", serial: serial, address: nil),
                       "another Libre 2 nearby")
    }

    func testNewerSensorsAreMatchedByAddress() {
        XCTAssertTrue(LibreAdvertisement.mayBelong(name: "A4B1C2D3E4F5", serial: serial, address: address))
        XCTAssertFalse(LibreAdvertisement.mayBelong(name: "A4B1C2D3E4F6", serial: serial, address: address))
        XCTAssertTrue(LibreAdvertisement.mayBelong(name: "A4B1C2D3E4F6", serial: serial, address: nil),
                      "without a known address, don't rule it out")
    }

    func testUnknownNamesAreNotRuledOut() {
        XCTAssertTrue(LibreAdvertisement.mayBelong(name: "", serial: serial, address: address))
        XCTAssertTrue(LibreAdvertisement.mayBelong(name: "ABBOTT", serial: serial, address: address))
        XCTAssertTrue(LibreAdvertisement.mayBelong(name: "ABBOTT3MH009ZZZZZ", serial: nil, address: nil))
    }

    func testAddressFromEnableResponse() {
        XCTAssertEqual(LibreSensorRecord.bluetoothAddress(fromEnableResponse: [0xF5, 0xE4, 0xD3, 0xC2, 0xB1, 0xA4]), address)
        XCTAssertNil(LibreSensorRecord.bluetoothAddress(fromEnableResponse: [0x01, 0x02]))
        XCTAssertNil(LibreSensorRecord.bluetoothAddress(fromEnableResponse: nil))
    }
}
