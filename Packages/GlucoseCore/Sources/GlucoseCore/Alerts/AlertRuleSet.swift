import Foundation

/// Up to 5 low and 5 high rules.
public struct AlertRuleSet: Codable, Hashable, Sendable {
    public static let maxRulesPerDirection = 5
    /// Without an enabled low rule at or below this value, the editor warns about a missing urgent low.
    public static let urgentLowMgdL: Double = 60
    /// Thresholds outside this range are rejected by the editor.
    public static let thresholdRangeMgdL: ClosedRange<Double> = 40...400

    public private(set) var rules: [AlertRule]

    public enum RuleSetError: Error, Equatable {
        case tooManyRules(AlertDirection)
        case thresholdOutOfRange(Double)
        case ruleNotFound(UUID)
    }

    public init(rules: [AlertRule] = []) throws {
        self.rules = []
        for rule in rules {
            try add(rule)
        }
    }

    public func rules(for direction: AlertDirection) -> [AlertRule] {
        rules.filter { $0.direction == direction }
    }

    public mutating func add(_ rule: AlertRule) throws {
        guard rules(for: rule.direction).count < Self.maxRulesPerDirection else {
            throw RuleSetError.tooManyRules(rule.direction)
        }
        guard Self.thresholdRangeMgdL.contains(rule.thresholdMgdL) else {
            throw RuleSetError.thresholdOutOfRange(rule.thresholdMgdL)
        }
        rules.append(rule)
    }

    public mutating func update(_ rule: AlertRule) throws {
        guard let index = rules.firstIndex(where: { $0.id == rule.id }) else {
            throw RuleSetError.ruleNotFound(rule.id)
        }
        guard Self.thresholdRangeMgdL.contains(rule.thresholdMgdL) else {
            throw RuleSetError.thresholdOutOfRange(rule.thresholdMgdL)
        }
        if rules[index].direction != rule.direction,
           rules(for: rule.direction).count >= Self.maxRulesPerDirection {
            throw RuleSetError.tooManyRules(rule.direction)
        }
        rules[index] = rule
    }

    public mutating func remove(id: UUID) {
        rules.removeAll { $0.id == id }
    }

    /// Copy of a rule with a new id, for quick setup.
    public mutating func duplicate(id: UUID) throws {
        guard var copy = rules.first(where: { $0.id == id }) else { throw RuleSetError.ruleNotFound(id) }
        copy.id = UUID()
        copy.name += " (copy)"
        try add(copy)
    }

    // MARK: Validation

    public enum Issue: Hashable, Sendable {
        case duplicateThreshold(AlertDirection, Double)
        case lowAboveHigh(lowMgdL: Double, highMgdL: Double)
        case noUrgentLow
        case noEnabledRules(AlertDirection)
    }

    /// Warnings shown in the rule editor. They don't block saving.
    public func validate() -> [Issue] {
        var issues: [Issue] = []
        for direction in AlertDirection.allCases {
            let enabled = rules(for: direction).filter(\.isEnabled)
            if enabled.isEmpty {
                issues.append(.noEnabledRules(direction))
            }
            var seen = Set<Double>()
            for rule in enabled {
                if !seen.insert(rule.thresholdMgdL).inserted {
                    issues.append(.duplicateThreshold(direction, rule.thresholdMgdL))
                }
            }
        }
        let lows = rules(for: .low).filter(\.isEnabled)
        let highs = rules(for: .high).filter(\.isEnabled)
        if let highestLow = lows.map(\.thresholdMgdL).max(),
           let lowestHigh = highs.map(\.thresholdMgdL).min(),
           highestLow >= lowestHigh {
            issues.append(.lowAboveHigh(lowMgdL: highestLow, highMgdL: lowestHigh))
        }
        if !lows.contains(where: { $0.thresholdMgdL <= Self.urgentLowMgdL }) {
            issues.append(.noUrgentLow)
        }
        return issues
    }

    // MARK: Presets

    /// The example from the project plan: <80 silent, <70 tune, <60 voice (critical); >180 silent, >220 tune, >250 voice.
    public static func basic() -> AlertRuleSet {
        // Force-try is safe: the preset is within limits and covered by tests.
        try! AlertRuleSet(rules: [
            AlertRule(name: "Low", direction: .low, thresholdMgdL: 80, sound: .silent, repeatIntervalMinutes: nil),
            AlertRule(name: "Lower", direction: .low, thresholdMgdL: 70, sound: .tune(name: "chime"), repeatIntervalMinutes: 10),
            AlertRule(name: "Urgent low", direction: .low, thresholdMgdL: 60, sound: .voice(clip: "glucose_very_low"),
                      isCritical: true, repeatIntervalMinutes: 5),
            AlertRule(name: "High", direction: .high, thresholdMgdL: 180, sound: .silent, repeatIntervalMinutes: nil,
                      confirmationMinutes: 15),
            AlertRule(name: "Higher", direction: .high, thresholdMgdL: 220, sound: .tune(name: "chime"), repeatIntervalMinutes: 30,
                      confirmationMinutes: 15),
            AlertRule(name: "Very high", direction: .high, thresholdMgdL: 250, sound: .voice(clip: "glucose_high"),
                      repeatIntervalMinutes: 30),
        ])
    }

    /// Fewer, louder alerts that only run overnight, plus an always-on urgent low.
    public static func night() -> AlertRuleSet {
        try! AlertRuleSet(rules: [
            AlertRule(name: "Night low", direction: .low, thresholdMgdL: 70, sound: .tune(name: "alarm"),
                      isCritical: true, repeatIntervalMinutes: 5, schedule: .nightOnly, confirmationMinutes: 10),
            AlertRule(name: "Urgent low", direction: .low, thresholdMgdL: 55, sound: .voice(clip: "glucose_very_low"),
                      isCritical: true, repeatIntervalMinutes: 5),
            AlertRule(name: "Night high", direction: .high, thresholdMgdL: 250, sound: .tune(name: "chime"),
                      repeatIntervalMinutes: 60, schedule: .nightOnly, confirmationMinutes: 30),
        ])
    }

    /// Earlier warnings with tighter thresholds.
    public static func sensitive() -> AlertRuleSet {
        try! AlertRuleSet(rules: [
            AlertRule(name: "Heading low", direction: .low, thresholdMgdL: 90, sound: .silent, repeatIntervalMinutes: nil),
            AlertRule(name: "Low", direction: .low, thresholdMgdL: 75, sound: .tune(name: "chime"), repeatIntervalMinutes: 10),
            AlertRule(name: "Urgent low", direction: .low, thresholdMgdL: 55, sound: .voice(clip: "glucose_very_low"),
                      isCritical: true, repeatIntervalMinutes: 5),
            AlertRule(name: "High", direction: .high, thresholdMgdL: 160, sound: .silent, repeatIntervalMinutes: nil,
                      confirmationMinutes: 15),
            AlertRule(name: "Very high", direction: .high, thresholdMgdL: 220, sound: .voice(clip: "glucose_high"),
                      repeatIntervalMinutes: 30),
        ])
    }
}
