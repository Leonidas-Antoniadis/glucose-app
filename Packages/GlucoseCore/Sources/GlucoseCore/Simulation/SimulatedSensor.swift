import Foundation

/// Deterministic fake sensor for development, demos and tests, so UI and alert work
/// never needs a real (and expensive) sensor.
public struct SimulatedSensor: Sendable {
    public let serial: String
    public let startedAt: Date
    /// Baseline the curve oscillates around.
    public var baselineMgdL: Double = 130
    /// Main swing (meals / daily rhythm).
    public var amplitudeMgdL: Double = 70
    /// Period of the main swing in minutes.
    public var periodMinutes: Double = 240
    /// Small "noise" wobble.
    public var noiseMgdL: Double = 6

    public init(serial: String = "SIM-0001", startedAt: Date) {
        self.serial = serial
        self.startedAt = startedAt
    }

    public func reading(atMinute minute: Int) -> GlucoseReading {
        let t = Double(minute)
        let main = sin(2 * .pi * t / periodMinutes) * amplitudeMgdL
        let secondary = sin(2 * .pi * t / 97 + 1.3) * amplitudeMgdL * 0.25
        let noise = sin(t * 12.9898).truncatingRemainder(dividingBy: 1) * noiseMgdL
        let value = min(400, max(40, baselineMgdL + main + secondary + noise))
        return GlucoseReading(
            sensorSerial: serial,
            minuteIndex: minute,
            timestamp: startedAt.addingTimeInterval(t * 60),
            mgdL: value.rounded(),
            source: .simulated
        )
    }

    public func readings(minutes range: Range<Int>) -> [GlucoseReading] {
        range.map(reading(atMinute:))
    }
}
