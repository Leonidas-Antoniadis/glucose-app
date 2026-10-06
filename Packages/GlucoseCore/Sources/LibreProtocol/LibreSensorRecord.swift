import Foundation
import GlucoseCore

/// Everything the app remembers about the paired sensor.
public struct LibreSensorRecord: Codable, Hashable, Sendable {
    public var uid: [UInt8]
    public var patchInfo: [UInt8]
    public var type: LibreSensorType
    public var serial: String
    /// Sensor start, derived from its age at pairing time.
    public var activatedAt: Date
    public var maxLifeMinutes: Int
    /// Increments with every Bluetooth connection (part of the unlock payload).
    public var unlockCount: Int
    /// CoreBluetooth identifier, stored once a packet from this peripheral decrypted correctly.
    public var peripheralIdentifier: UUID?
    /// The sensor's Bluetooth MAC address, from its answer to the enable-streaming command
    /// (most significant byte first). Newer sensors advertise it as their name.
    public var bluetoothAddress: [UInt8]?
    public var calibration: Calibration
    public var calibrationPoints: [CalibrationPoint]
    public var pairedAt: Date

    public static let warmUpMinutes = 60

    public init(uid: [UInt8], patchInfo: [UInt8], ageMinutes: Int, maxLifeMinutes: Int, now: Date) {
        self.uid = uid
        self.patchInfo = patchInfo
        self.type = LibreSensorType(patchInfo: patchInfo)
        self.serial = LibreSerial.serial(uid: uid, patchInfo: patchInfo)
        let minuteAligned = (now.timeIntervalSince1970 / 60).rounded(.down) * 60
        self.activatedAt = Date(timeIntervalSince1970: minuteAligned - Double(ageMinutes) * 60)
        self.maxLifeMinutes = maxLifeMinutes > 0 ? maxLifeMinutes : LibreSensorType(patchInfo: patchInfo).lifetimeMinutes
        self.unlockCount = 0
        self.peripheralIdentifier = nil
        self.bluetoothAddress = nil
        self.calibration = .uncalibrated
        self.calibrationPoints = []
        self.pairedAt = now
    }

    /// The record after an NFC pairing. Pairing the *same* sensor again (for example after
    /// LibreLink took it back) keeps its calibration; the unlock counter and Bluetooth
    /// peripheral start over because the sensor was re-enabled.
    public static func paired(uid: [UInt8], patchInfo: [UInt8], ageMinutes: Int, maxLifeMinutes: Int, now: Date,
                              previous: LibreSensorRecord?) -> LibreSensorRecord {
        var record = LibreSensorRecord(uid: uid, patchInfo: patchInfo, ageMinutes: ageMinutes, maxLifeMinutes: maxLifeMinutes, now: now)
        if let previous, previous.uid == uid {
            record.calibrationPoints = previous.calibrationPoints
            record.calibration = Calibration.fit(previous.calibrationPoints, now: now)
            record.pairedAt = previous.pairedAt
        }
        return record
    }

    public var expiresAt: Date {
        activatedAt.addingTimeInterval(Double(maxLifeMinutes) * 60)
    }

    public var warmUpEndsAt: Date {
        activatedAt.addingTimeInterval(Double(Self.warmUpMinutes) * 60)
    }

    public func ageMinutes(at date: Date) -> Int {
        Int(date.timeIntervalSince(activatedAt) / 60)
    }

    public func timestamp(forMinute minute: Int) -> Date {
        activatedAt.addingTimeInterval(Double(minute) * 60)
    }

    /// Returns the payload for the next Bluetooth connection and advances the counter.
    public mutating func nextUnlockPayload() throws -> [UInt8] {
        unlockCount += 1
        return try Libre2Crypto.streamingUnlockPayload(uid: uid, patchInfo: patchInfo,
                                                       unlockCount: UInt16(truncatingIfNeeded: unlockCount))
    }

    /// Adds a fingerstick calibration using the raw value closest in time, and refits.
    @discardableResult
    public mutating func addCalibration(referenceMgdL: Double, raw: Double, date: Date) -> Calibration {
        calibrationPoints.append(CalibrationPoint(date: date, referenceMgdL: referenceMgdL, raw: raw))
        calibrationPoints = calibrationPoints.filter { date.timeIntervalSince($0.date) <= Calibration.maxAgeHours * 3600 }
        calibration = Calibration.fit(calibrationPoints, now: date)
        return calibration
    }

    /// The MAC address in the sensor's 6-byte answer to the enable-streaming command, which sends it
    /// least significant byte first (as DiaBLE reads it).
    public static func bluetoothAddress(fromEnableResponse response: [UInt8]?) -> [UInt8]? {
        guard let response, response.count == 6 else { return nil }
        return Array(response.reversed())
    }

    /// Converts raw sensor readings into glucose readings, skipping warm-up and error values.
    public func glucoseReadings(from raws: [LibreRawReading], liveSource: GlucoseReading.Source) -> [GlucoseReading] {
        raws.compactMap { raw in
            guard !raw.hasError, raw.minuteIndex >= Self.warmUpMinutes, raw.minuteIndex <= maxLifeMinutes,
                  let mgdL = ReadingPipeline.clamped(calibration.mgdL(fromRaw: Double(raw.raw)).rounded()) else { return nil }
            return GlucoseReading(
                sensorSerial: serial,
                minuteIndex: raw.minuteIndex,
                timestamp: timestamp(forMinute: raw.minuteIndex),
                mgdL: mgdL,
                source: raw.isHistory ? .backfill : liveSource,
                raw: Double(raw.raw)
            )
        }
    }
}
