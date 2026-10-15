import Testing
import Foundation
@testable import WakeUpCore

private let t0 = Date(timeIntervalSince1970: 1_000_000)

private func readings(
    battery: Int? = 80, onBattery: Bool = false, thermal: ThermalLevel = .nominal,
    lidClosed: Bool = false, since: Date? = nil
) -> SafetyReadings {
    SafetyReadings(batteryLevel: battery, onBattery: onBattery, thermal: thermal,
                   lidClosed: lidClosed, lidClosedOnBatterySince: since, now: t0)
}

private func session(lidActive: Bool = false, enabledAt: Date? = nil) -> Session {
    Session(startedAt: t0.addingTimeInterval(-100_000), lidModeActive: lidActive, lidModeEnabledAt: enabledAt)
}

struct SafetyCase: Sendable, CustomTestStringConvertible {
    let name: String
    let r: SafetyReadings
    let s: Session
    let settings: SafetySettings
    let expected: SafetyDecision
    var testDescription: String { name }
}

private let lowBatteryCases: [SafetyCase] = [
    SafetyCase(name: "19% on battery stops", r: readings(battery: 19, onBattery: true), s: session(), settings: SafetySettings(), expected: .stopSession(.lowBattery)),
    SafetyCase(name: "20% on battery ok", r: readings(battery: 20, onBattery: true), s: session(), settings: SafetySettings(), expected: .none),
    SafetyCase(name: "10% on AC ok", r: readings(battery: 10, onBattery: false), s: session(), settings: SafetySettings(), expected: .none),
    SafetyCase(name: "rule disabled", r: readings(battery: 5, onBattery: true), s: session(), settings: SafetySettings(batteryRuleEnabled: false), expected: .none),
]

@Test(arguments: lowBatteryCases) func lowBatteryStops(_ c: SafetyCase) {
    #expect(SafetyPolicy.evaluate(c.r, session: c.s, settings: c.settings) == c.expected)
}

private let thermalCases: [SafetyCase] = [
    SafetyCase(name: "critical lid closed stops", r: readings(thermal: .critical, lidClosed: true), s: session(lidActive: true), settings: SafetySettings(), expected: .stopSession(.thermal)),
    SafetyCase(name: "critical lid open suspends", r: readings(thermal: .critical), s: session(lidActive: true), settings: SafetySettings(), expected: .suspendLidMode(.thermal)),
    SafetyCase(name: "serious lid active suspends", r: readings(thermal: .serious), s: session(lidActive: true), settings: SafetySettings(), expected: .suspendLidMode(.thermal)),
    SafetyCase(name: "serious lid inactive none", r: readings(thermal: .serious), s: session(lidActive: false), settings: SafetySettings(), expected: .none),
    SafetyCase(name: "thermal rule disabled", r: readings(thermal: .critical, lidClosed: true), s: session(lidActive: true), settings: SafetySettings(thermalRuleEnabled: false), expected: .none),
]

@Test(arguments: thermalCases) func thermalRules(_ c: SafetyCase) {
    #expect(SafetyPolicy.evaluate(c.r, session: c.s, settings: c.settings) == c.expected)
}

private let lidLimitCases: [SafetyCase] = [
    SafetyCase(name: "exactly 4h suspends", r: readings(onBattery: true, lidClosed: true, since: t0.addingTimeInterval(-14400)), s: session(lidActive: true), settings: SafetySettings(), expected: .suspendLidMode(.lidOnBatteryLimit)),
    SafetyCase(name: "4h minus 1s none", r: readings(onBattery: true, lidClosed: true, since: t0.addingTimeInterval(-14399)), s: session(lidActive: true), settings: SafetySettings(), expected: .none),
    SafetyCase(name: "re-enable resets counter", r: readings(onBattery: true, lidClosed: true, since: t0.addingTimeInterval(-20000)), s: session(lidActive: true, enabledAt: t0.addingTimeInterval(-60)), settings: SafetySettings(), expected: .none),
    SafetyCase(name: "rule disabled", r: readings(onBattery: true, lidClosed: true, since: t0.addingTimeInterval(-20000)), s: session(lidActive: true), settings: SafetySettings(lidLimitRuleEnabled: false), expected: .none),
    SafetyCase(name: "lid mode inactive", r: readings(onBattery: true, lidClosed: true, since: t0.addingTimeInterval(-20000)), s: session(lidActive: false), settings: SafetySettings(), expected: .none),
    SafetyCase(name: "no since", r: readings(onBattery: true, lidClosed: true, since: nil), s: session(lidActive: true), settings: SafetySettings(), expected: .none),
]

@Test(arguments: lidLimitCases) func lidLimit(_ c: SafetyCase) {
    #expect(SafetyPolicy.evaluate(c.r, session: c.s, settings: c.settings) == c.expected)
}

@Test func stopBeatsSuspend() {
    let r = readings(battery: 10, onBattery: true, thermal: .serious)
    #expect(SafetyPolicy.evaluate(r, session: session(lidActive: true), settings: SafetySettings()) == .stopSession(.lowBattery))
}

@Test func noBatteryNeverBlocksOrStops() {
    let r = readings(battery: nil, onBattery: false)
    #expect(SafetyPolicy.evaluate(r, session: session(), settings: SafetySettings()) == .none)
    #expect(SafetyPolicy.canStart(r, settings: SafetySettings()))
}

@Test func canStartBlocksBelowThreshold() {
    #expect(!SafetyPolicy.canStart(readings(battery: 15, onBattery: true), settings: SafetySettings()))
    #expect(SafetyPolicy.canStart(readings(battery: 15, onBattery: false), settings: SafetySettings()))
}
