import XCTest
@testable import LibreProtocol

final class LibreSimulatorTests: XCTestCase {
    private let uid = LibreSimulator.demoUID
    private let patch = LibreSimulator.demoPatchInfo
    private let raw: (Int) -> Int = { 1000 + $0 % 500 }

    func testSimulatedBLEPacketDecodesThroughTheRealPipeline() throws {
        let packet = try LibreSimulator.blePacket(ageMinutes: 3000, raw: raw)
        XCTAssertEqual(packet.count, 46)
        let parsed = try LibreBLEPacket(decrypted: Libre2Crypto.decryptBLE(uid: uid, packet: packet))
        XCTAssertEqual(parsed.ageMinutes, 3000)
        XCTAssertEqual(parsed.trend.map(\.minuteIndex), [3000, 2998, 2996, 2994, 2993, 2988, 2985])
        XCTAssertEqual(parsed.trend.map(\.raw), parsed.trend.map { raw($0.minuteIndex) })
        XCTAssertEqual(parsed.history.map(\.minuteIndex), [2985, 2970, 2955])
        XCTAssertEqual(parsed.history.map(\.raw), parsed.history.map { raw($0.minuteIndex) })
        XCTAssertEqual(parsed.latest?.rawTemperature, LibreSimulator.defaultTemperature)
    }

    func testSimulatedFRAMDecodes() throws {
        let encrypted = try LibreSimulator.fram(ageMinutes: 1500, raw: raw)
        let fram = try LibreFRAM(decrypted: Libre2Crypto.decryptFRAM(uid: uid, patchInfo: patch, data: encrypted))
        XCTAssertEqual(fram.state, .active)
        XCTAssertEqual(fram.ageMinutes, 1500)
        XCTAssertEqual(fram.maxLifeMinutes, 15 * 1440)
        XCTAssertEqual(fram.trend.count, 16)
        XCTAssertEqual(fram.trend.map(\.raw), fram.trend.map { raw($0.minuteIndex) })
        XCTAssertEqual(fram.trend.first?.minuteIndex, 1500)
        XCTAssertEqual(fram.history.count, 32)
        XCTAssertEqual(fram.history.first?.minuteIndex, 1485)
        XCTAssertEqual(fram.history.map(\.raw), fram.history.map { raw($0.minuteIndex) })
    }

    func testLayoutsCoverEveryByte() {
        for (regions, size) in [(LibreLayout.blePacket, 46), (LibreLayout.bleDecrypted, 44), (LibreLayout.fram, 344)] {
            for index in 0..<size {
                XCTAssertEqual(regions.filter { $0.range.contains(index) }.count, 1, "byte \(index) of \(size)")
            }
        }
    }
}
