import Testing
import Foundation
@testable import LidlessCore

@Test func minutesEndDate() { let t0 = Date(timeIntervalSince1970: 1000)
    #expect(SessionDuration.minutes(15).endDate(from: t0) == t0.addingTimeInterval(900))
    #expect(SessionDuration.indefinite.endDate(from: t0) == nil)
    #expect(SessionDuration.until(t0.addingTimeInterval(42)).endDate(from: t0) == t0.addingTimeInterval(42)) }
@Test func settingsDefaults() { let s = LidlessSettings()
    #expect(s.defaultDuration == .indefinite); #expect(s.presetMinutes == [15, 60, 180])
    #expect(!s.keepDisplayOn && !s.lidModeEnabled && !s.showTimerInMenuBar && !s.startSessionOnLaunch)
    #expect(s.safety == SafetySettings(batteryRuleEnabled: true, batteryThreshold: 20, thermalRuleEnabled: true, lidLimitRuleEnabled: true, lidLimitMinutes: 240)) }
@Test func settingsCodableRoundTrip() throws { var s = LidlessSettings(); s.defaultDuration = .minutes(60); s.safety.batteryThreshold = 35
    #expect(try JSONDecoder().decode(LidlessSettings.self, from: JSONEncoder().encode(s)) == s) }
@Test func settingsDecodeMissingFieldsUsesDefaults() throws {
    var s = LidlessSettings(); s.defaultDuration = .minutes(60); s.presetMinutes = [5, 10]; s.keepDisplayOn = true
    s.lidModeEnabled = true; s.showTimerInMenuBar = true; s.startSessionOnLaunch = true
    s.safety = SafetySettings(batteryRuleEnabled: false, batteryThreshold: 35, thermalRuleEnabled: false,
                              lidLimitRuleEnabled: false, lidLimitMinutes: 99)
    var json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(s)) as? [String: Any])
    json["showTimerInMenuBar"] = nil
    var safety = try #require(json["safety"] as? [String: Any])
    safety["lidLimitMinutes"] = nil
    json["safety"] = safety
    let decoded = try JSONDecoder().decode(LidlessSettings.self, from: JSONSerialization.data(withJSONObject: json))
    var expected = s; expected.showTimerInMenuBar = false; expected.safety.lidLimitMinutes = 240
    #expect(decoded == expected) }
