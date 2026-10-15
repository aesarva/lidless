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

    /// Missing keys fall back to defaults, so adding a field never resets saved settings.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SafetySettings()
        batteryRuleEnabled = try c.decodeIfPresent(Bool.self, forKey: .batteryRuleEnabled) ?? d.batteryRuleEnabled
        batteryThreshold = try c.decodeIfPresent(Int.self, forKey: .batteryThreshold) ?? d.batteryThreshold
        thermalRuleEnabled = try c.decodeIfPresent(Bool.self, forKey: .thermalRuleEnabled) ?? d.thermalRuleEnabled
        lidLimitRuleEnabled = try c.decodeIfPresent(Bool.self, forKey: .lidLimitRuleEnabled) ?? d.lidLimitRuleEnabled
        lidLimitMinutes = try c.decodeIfPresent(Int.self, forKey: .lidLimitMinutes) ?? d.lidLimitMinutes
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

    /// Missing keys fall back to defaults, so adding a field never resets saved settings.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = WakeUpSettings()
        defaultDuration = try c.decodeIfPresent(SessionDuration.self, forKey: .defaultDuration) ?? d.defaultDuration
        presetMinutes = try c.decodeIfPresent([Int].self, forKey: .presetMinutes) ?? d.presetMinutes
        keepDisplayOn = try c.decodeIfPresent(Bool.self, forKey: .keepDisplayOn) ?? d.keepDisplayOn
        lidModeEnabled = try c.decodeIfPresent(Bool.self, forKey: .lidModeEnabled) ?? d.lidModeEnabled
        showTimerInMenuBar = try c.decodeIfPresent(Bool.self, forKey: .showTimerInMenuBar) ?? d.showTimerInMenuBar
        startSessionOnLaunch = try c.decodeIfPresent(Bool.self, forKey: .startSessionOnLaunch) ?? d.startSessionOnLaunch
        safety = try c.decodeIfPresent(SafetySettings.self, forKey: .safety) ?? d.safety
    }
}
