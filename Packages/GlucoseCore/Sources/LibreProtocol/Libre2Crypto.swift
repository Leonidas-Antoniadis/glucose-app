import Foundation

/// Libre 2 (EU) encryption for the FRAM contents, the NFC "enable streaming" command and the
/// Bluetooth stream.
///
/// The algorithm follows the community's reverse-engineering, as published in open-source
/// projects such as LibreTransmitter, DiaBLE and xDrip. It is **experimental**: this repository
/// verifies it only for internal consistency, not against a real sensor.
///
/// `uid` is the sensor UID in sensor byte order (the reverse of CoreNFC's `tag.identifier`),
/// so `uid[7] == 0xE0` and `uid[6] == 0x07`.
public enum Libre2Crypto {
    static let key: [UInt16] = [0xA0C5, 0x6860, 0x0000, 0x14C6]

    /// Time value used for the enable-streaming command and the BLE unlock payload.
    public static let enableTime: UInt32 = 42
    public static let enableStreamingCommand: UInt8 = 0xA1
    public static let enableStreamingSubcommand: UInt8 = 0x1E
    public static let patchInfoCommand: UInt8 = 0xA1
    public static let activateCommand: UInt8 = 0xA1
    public static let activateSubcommand: UInt8 = 0x1B
    /// Fixed value used to derive the activation code (and parts of the Bluetooth key).
    static let activateSecret: UInt16 = 0x1B6A

    // MARK: Building blocks

    static func word(_ high: UInt8, _ low: UInt8) -> UInt16 {
        UInt16(high) << 8 | UInt16(low)
    }

    static func processCrypto(_ input: [UInt16]) -> [UInt16] {
        func op(_ value: UInt16) -> UInt16 {
            var result = value >> 2
            if value & 1 != 0 { result ^= key[1] }
            if value & 2 != 0 { result ^= key[0] }
            return result
        }
        let r0 = op(input[0]) ^ input[3]
        let r1 = op(r0) ^ input[2]
        let r2 = op(r1) ^ input[1]
        let r3 = op(r2) ^ input[0]
        let r4 = op(r3)
        let r5 = op(r4 ^ r0)
        let r6 = op(r5 ^ r1)
        let r7 = op(r6 ^ r2)
        return [r3 ^ r7, r2 ^ r6, r1 ^ r5, r0 ^ r4]
    }

    static func prepareVariables(uid: [UInt8], x: UInt16, y: UInt16) -> [UInt16] {
        let s1 = UInt16(truncatingIfNeeded: UInt(word(uid[5], uid[4])) + UInt(x) + UInt(y))
        let s2 = UInt16(truncatingIfNeeded: UInt(word(uid[3], uid[2])) + UInt(key[2]))
        let s3 = UInt16(truncatingIfNeeded: UInt(word(uid[1], uid[0])) + UInt(x) * 2)
        let s4 = 0x241A ^ key[3]
        return [s1, s2, s3, s4]
    }

    static func prepareVariables2(uid: [UInt8], i1: UInt16, i2: UInt16, i3: UInt16, i4: UInt16) -> [UInt16] {
        let s1 = UInt16(truncatingIfNeeded: UInt(word(uid[5], uid[4])) + UInt(i1))
        let s2 = UInt16(truncatingIfNeeded: UInt(word(uid[3], uid[2])) + UInt(i2))
        let s3 = UInt16(truncatingIfNeeded: UInt(word(uid[1], uid[0])) + UInt(i3) + UInt(key[2]))
        let s4 = UInt16(truncatingIfNeeded: UInt(i4) + UInt(key[3]))
        return [s1, s2, s3, s4]
    }

    static func usefulFunction(uid: [UInt8], x: UInt16, y: UInt16) -> [UInt8] {
        let blockKey = processCrypto(prepareVariables(uid: uid, x: x, y: y))
        let r1 = blockKey[0] ^ 0x4163
        let r2 = blockKey[1] ^ 0x4344
        return [
            UInt8(truncatingIfNeeded: r1), UInt8(truncatingIfNeeded: r1 >> 8),
            UInt8(truncatingIfNeeded: r2), UInt8(truncatingIfNeeded: r2 >> 8),
        ]
    }

    static func bytes(_ words: [UInt16]) -> [UInt8] {
        words.flatMap { [UInt8(truncatingIfNeeded: $0), UInt8(truncatingIfNeeded: $0 >> 8)] }
    }

    static func validate(uid: [UInt8], patchInfo: [UInt8]? = nil) throws {
        guard uid.count == 8 else { throw LibreProtocolError.invalidUID }
        if let patchInfo, patchInfo.count < 6 { throw LibreProtocolError.invalidPatchInfo }
    }

    // MARK: FRAM

    /// Decrypts the 344-byte FRAM (43 blocks of 8 bytes). The cipher is a XOR stream,
    /// so the same function also encrypts.
    public static func decryptFRAM(uid: [UInt8], patchInfo: [UInt8], data: [UInt8]) throws -> [UInt8] {
        try validate(uid: uid, patchInfo: patchInfo)
        guard data.count >= 344 else { throw LibreProtocolError.invalidLength(expected: 344, actual: data.count) }
        let argument = word(patchInfo[5], patchInfo[4]) ^ 0x44
        var result = [UInt8]()
        result.reserveCapacity(344)
        for block in 0..<43 {
            let keyBytes = bytes(processCrypto(prepareVariables(uid: uid, x: UInt16(block), y: argument)))
            for i in 0..<8 {
                result.append(data[block * 8 + i] ^ keyBytes[i])
            }
        }
        return result
    }

    // MARK: NFC enable streaming

    /// Parameters for the NFC custom command 0xA1 that enables Bluetooth streaming:
    /// the sub-command byte followed by four derived bytes.
    public static func enableStreamingParameters(uid: [UInt8], patchInfo: [UInt8]) throws -> [UInt8] {
        try validate(uid: uid, patchInfo: patchInfo)
        let y = UInt16(enableTime & 0xFFFF) ^ word(patchInfo[5], patchInfo[4])
        return [enableStreamingSubcommand] + usefulFunction(uid: uid, x: UInt16(enableStreamingSubcommand), y: y)
    }

    // MARK: NFC activate

    /// Parameters for the NFC custom command 0xA1 that starts a new sensor (state "Not activated"
    /// to "Warming up"): the sub-command byte followed by four derived bytes. Starting can't be undone.
    public static func activateParameters(uid: [UInt8]) throws -> [UInt8] {
        try validate(uid: uid)
        return [activateSubcommand] + usefulFunction(uid: uid, x: UInt16(activateSubcommand), y: activateSecret)
    }

    // MARK: BLE

    /// The 12-byte payload written to the sensor after each Bluetooth connection.
    /// `unlockCount` must increase with every connection.
    public static func streamingUnlockPayload(uid: [UInt8], patchInfo: [UInt8], enableTime: UInt32 = enableTime,
                                              unlockCount: UInt16) throws -> [UInt8] {
        try validate(uid: uid, patchInfo: patchInfo)
        let time = enableTime &+ UInt32(unlockCount)
        let b: [UInt8] = [
            UInt8(time & 0xFF), UInt8((time >> 8) & 0xFF),
            UInt8((time >> 16) & 0xFF), UInt8((time >> 24) & 0xFF),
        ]

        let ad = usefulFunction(uid: uid, x: UInt16(activateSubcommand), y: activateSecret)
        let ed = usefulFunction(uid: uid, x: UInt16(enableStreamingSubcommand),
                                y: UInt16(enableTime & 0xFFFF) ^ word(patchInfo[5], patchInfo[4]))

        let t11 = word(ed[1], ed[0]) ^ word(b[3], b[2])
        let t12 = word(ad[1], ad[0])
        let t13 = word(ed[3], ed[2]) ^ word(b[1], b[0])
        let t14 = word(ad[3], ad[2])
        let t2 = processCrypto(prepareVariables2(uid: uid, i1: t11, i2: t12, i3: t13, i4: t14))
        let t2Bytes = bytes(t2)

        let t31 = LibreCRC.crc16([0xC1, 0xC4, 0xC3, 0xC0, 0xD4, 0xE1, 0xE7, 0xBA, t2Bytes[0], t2Bytes[1]]).byteSwapped
        let t32 = LibreCRC.crc16(Array(t2Bytes[2..<8])).byteSwapped
        let t33 = LibreCRC.crc16([ad[0], ad[1], ad[2], ad[3], ed[0], ed[1]]).byteSwapped
        let t34 = LibreCRC.crc16([ed[2], ed[3], b[0], b[1], b[2], b[3]]).byteSwapped
        let t4 = processCrypto(prepareVariables2(uid: uid, i1: t31, i2: t32, i3: t33, i4: t34))

        return b + bytes(t4)
    }

    /// Bluetooth keystream for a packet, seeded by the packet's first two (plain) bytes.
    static func bleKeyStream(uid: [UInt8], seedLow: UInt8, seedHigh: UInt8, length: Int) -> [UInt8] {
        let d = usefulFunction(uid: uid, x: UInt16(activateSubcommand), y: activateSecret)
        let x = (word(d[1], d[0]) ^ word(d[3], d[2])) | 0x63
        let y = word(seedHigh, seedLow) ^ 0x63
        var keyWords = processCrypto(prepareVariables(uid: uid, x: x, y: y))
        var stream = [UInt8]()
        while stream.count < length {
            stream += bytes(keyWords)
            keyWords = processCrypto(keyWords)
        }
        return Array(stream.prefix(length))
    }

    /// Decrypts a 46-byte BLE packet into 44 bytes (readings, sensor age, CRC) and checks the CRC.
    /// A CRC failure means a corrupt packet or a different sensor.
    public static func decryptBLE(uid: [UInt8], packet: [UInt8]) throws -> [UInt8] {
        try validate(uid: uid)
        guard packet.count == 46 else { throw LibreProtocolError.invalidLength(expected: 46, actual: packet.count) }
        let payload = Array(packet[2...])
        let stream = bleKeyStream(uid: uid, seedLow: packet[0], seedHigh: packet[1], length: payload.count)
        let result = zip(payload, stream).map { $0 ^ $1 }
        guard LibreCRC.hasValidCRCInLastTwoBytes(result) else { throw LibreProtocolError.invalidCRC("BLE packet") }
        return result
    }

    /// Inverse of `decryptBLE`, used to build test fixtures.
    public static func encryptBLE(uid: [UInt8], plaintext: [UInt8], seed: (UInt8, UInt8)) throws -> [UInt8] {
        try validate(uid: uid)
        let stream = bleKeyStream(uid: uid, seedLow: seed.0, seedHigh: seed.1, length: plaintext.count)
        return [seed.0, seed.1] + zip(plaintext, stream).map { $0 ^ $1 }
    }
}

public enum LibreProtocolError: Error, Equatable, CustomStringConvertible {
    case invalidUID
    case invalidPatchInfo
    case invalidLength(expected: Int, actual: Int)
    case invalidCRC(String)
    case unsupportedSensor(String)

    public var description: String {
        switch self {
        case .invalidUID: return "The sensor ID is invalid."
        case .invalidPatchInfo: return "The sensor's patch info is invalid."
        case .invalidLength(let expected, let actual): return "Expected \(expected) bytes, got \(actual)."
        case .invalidCRC(let section): return "Checksum mismatch in \(section). The data is corrupt or from another sensor."
        case .unsupportedSensor(let detail): return "This sensor type isn't supported (\(detail))."
        }
    }
}
