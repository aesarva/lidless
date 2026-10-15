import Foundation

public struct SafetySettings: Codable, Equatable, Sendable {
    public var batteryRuleEnabled = true
    public var batteryThreshold = 20
    public var thermalRuleEnabled = true
    public var lidLimitRuleEnabled = true
    public var lidLimitMinutes = 240

    public init(
        batteryRuleEnabled: Bool = true,
        batteryThreshold: Int = 20,
        thermalRuleEnabled: Bool = true,
        lidLimitRuleEnabled: Bool = true,
        lidLimitMinutes: Int = 240
    ) {
        self.batteryRuleEnabled = batteryRuleEnabled
        self.batteryThreshold = batteryThreshold
        self.thermalRuleEnabled = thermalRuleEnabled
        self.lidLimitRuleEnabled = lidLimitRuleEnabled
        self.lidLimitMinutes = lidLimitMinutes
    }
}

public struct WakeUpSettings: Codable, Equatable, Sendable {
    public var defaultDuration: SessionDuration = .indefinite
    public var presetMinutes: [Int] = [15, 60, 180]
    public var keepDisplayOn = false
    public var lidModeEnabled = false
    public var showTimerInMenuBar = false
    public var startSessionOnLaunch = false
    public var safety = SafetySettings()

    public init() {}
}
