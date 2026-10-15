import Testing
import Foundation
@testable import WakeUpCore

@Test func minutesEndDate() { let t0 = Date(timeIntervalSince1970: 1000)
    #expect(SessionDuration.minutes(15).endDate(from: t0) == t0.addingTimeInterval(900))
    #expect(SessionDuration.indefinite.endDate(from: t0) == nil)
    #expect(SessionDuration.until(t0.addingTimeInterval(42)).endDate(from: t0) == t0.addingTimeInterval(42)) }
@Test func settingsDefaults() { let s = WakeUpSettings()
    #expect(s.defaultDuration == .indefinite); #expect(s.presetMinutes == [15, 60, 180])
    #expect(!s.keepDisplayOn && !s.lidModeEnabled && !s.showTimerInMenuBar && !s.startSessionOnLaunch)
    #expect(s.safety == SafetySettings(batteryRuleEnabled: true, batteryThreshold: 20, thermalRuleEnabled: true, lidLimitRuleEnabled: true, lidLimitMinutes: 240)) }
@Test func settingsCodableRoundTrip() throws { var s = WakeUpSettings(); s.defaultDuration = .minutes(60); s.safety.batteryThreshold = 35
    #expect(try JSONDecoder().decode(WakeUpSettings.self, from: JSONEncoder().encode(s)) == s) }
