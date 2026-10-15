import Foundation

public enum ThermalLevel: Int, Comparable, Sendable {
    case nominal, fair, serious, critical

    public static func < (lhs: ThermalLevel, rhs: ThermalLevel) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct SafetyReadings: Equatable, Sendable {
    public var batteryLevel: Int?
    public var onBattery: Bool
    public var thermal: ThermalLevel
    public var lidClosed: Bool
    public var lidClosedOnBatterySince: Date?
    public var now: Date

    public init(
        batteryLevel: Int?, onBattery: Bool, thermal: ThermalLevel,
        lidClosed: Bool, lidClosedOnBatterySince: Date?, now: Date
    ) {
        self.batteryLevel = batteryLevel
        self.onBattery = onBattery
        self.thermal = thermal
        self.lidClosed = lidClosed
        self.lidClosedOnBatterySince = lidClosedOnBatterySince
        self.now = now
    }
}

public enum SafetyDecision: Equatable, Sendable {
    case none
    case suspendLidMode(SafetyReason)
    case stopSession(SafetyReason)
}

public enum SafetyPolicy {
    public static func evaluate(_ r: SafetyReadings, session: Session, settings: SafetySettings) -> SafetyDecision {
        if lowBattery(r, settings) { return .stopSession(.lowBattery) }
        if settings.thermalRuleEnabled && r.lidClosed && r.thermal == .critical {
            return .stopSession(.thermal)
        }
        if settings.thermalRuleEnabled && session.lidModeActive && r.thermal >= .serious {
            return .suspendLidMode(.thermal)
        }
        if settings.lidLimitRuleEnabled && session.lidModeActive && r.lidClosed && r.onBattery,
           let since = r.lidClosedOnBatterySince {
            let start = max(since, session.lidModeEnabledAt ?? since)
            if r.now.timeIntervalSince(start) >= TimeInterval(settings.lidLimitMinutes * 60) {
                return .suspendLidMode(.lidOnBatteryLimit)
            }
        }
        return .none
    }

    public static func canStart(_ r: SafetyReadings, settings: SafetySettings) -> Bool {
        !lowBattery(r, settings)
    }

    private static func lowBattery(_ r: SafetyReadings, _ settings: SafetySettings) -> Bool {
        guard settings.batteryRuleEnabled, r.onBattery, let level = r.batteryLevel else { return false }
        return level < settings.batteryThreshold
    }
}
