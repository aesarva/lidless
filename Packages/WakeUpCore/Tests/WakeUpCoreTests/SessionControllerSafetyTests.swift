import Testing
import Foundation
@testable import WakeUpCore

@MainActor
struct SessionControllerSafetyTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let clock: MutableClock
    let assertions = FakeAssertions()
    let lid = FakeLid()
    let notifier = FakeNotifier()
    let store = MemorySettingsStore()
    let c: SessionController

    init() {
        clock = MutableClock(t0)
        c = SessionController(assertions: assertions, lid: lid, notifier: notifier,
                              settingsStore: store, clock: clock)
    }

    func readings(level: Int? = 80, onBattery: Bool = false, thermal: ThermalLevel = .nominal,
                  lidClosed: Bool = false, since: Date? = nil) -> SafetyReadings {
        SafetyReadings(batteryLevel: level, onBattery: onBattery, thermal: thermal,
                       lidClosed: lidClosed, lidClosedOnBatterySince: since, now: clock.now)
    }

    func startWithLid() {
        c.settings.lidModeEnabled = true
        c.start(.indefinite)
    }

    @Test func startWithLidModeEnables() {
        startWithLid()
        #expect(lid.enableCalls == 1)
        #expect(c.session?.lidModeActive == true)
        #expect(c.session?.lidModeEnabledAt == t0)
    }

    @Test func stopDisablesLid() {
        startWithLid()
        c.stop(.user)
        #expect(lid.disableCalls == 1)
    }

    @Test func appQuitDisablesLidMode() {
        startWithLid()
        c.stop(.appQuit)
        #expect(lid.disableCalls == 1)
        #expect(!notifier.posted.contains(.sessionEnded(.appQuit)))
    }

    @Test func lidEnableFailureKeepsSession() {
        lid.failEnable = true
        startWithLid()
        #expect(c.session != nil)
        #expect(c.session?.lidModeActive == false)
        #expect(c.session?.lidModeSuspendedReason == .helperUnavailable)
        #expect(c.attention == .helperUnavailable)
        #expect(notifier.posted.contains(.lidModeSuspended(.helperUnavailable)))
    }

    @Test func thermalSuspendsLidButKeepsSession() {
        startWithLid()
        c.update(readings: readings(thermal: .serious))
        #expect(c.session != nil)
        #expect(c.session?.lidModeActive == false)
        #expect(c.session?.lidModeSuspendedReason == .thermal)
        #expect(c.settings.lidModeEnabled == true)
        #expect(lid.disableCalls == 1)
        #expect(c.attention == .thermal)
        #expect(notifier.posted.contains(.lidModeSuspended(.thermal)))
    }

    @Test func userReenableClearsSuspensionAndResetsLimit() {
        startWithLid()
        let since = t0
        clock.advance(240 * 60)
        c.update(readings: readings(onBattery: true, lidClosed: true, since: since))
        #expect(c.session?.lidModeSuspendedReason == .lidOnBatteryLimit)
        #expect(c.session?.lidModeActive == false)

        clock.advance(60)
        c.setLidMode(true)
        #expect(c.session?.lidModeActive == true)
        #expect(c.session?.lidModeSuspendedReason == nil)
        #expect(c.session?.lidModeEnabledAt == clock.now)

        c.update(readings: readings(onBattery: true, lidClosed: true, since: since))
        #expect(c.session?.lidModeActive == true)
        #expect(c.session != nil)
    }

    @Test func setLidModeOffDisablesAndClears() {
        startWithLid()
        c.setLidMode(false)
        #expect(c.settings.lidModeEnabled == false)
        #expect(lid.disableCalls == 1)
        #expect(c.session?.lidModeActive == false)
    }

    @Test func lowBatteryStopsWithAttention() {
        c.start(.indefinite)
        c.update(readings: readings(level: 10, onBattery: true))
        #expect(c.state == .off)
        #expect(c.attention == .lowBattery)
        #expect(notifier.posted.last == .sessionEnded(.safety(.lowBattery)))
    }

    @Test func clearAttentionResets() {
        c.start(.indefinite)
        c.update(readings: readings(level: 10, onBattery: true))
        c.clearAttention()
        #expect(c.attention == nil)
    }

    @Test func suspendDisableFailureKeepsLidActiveAndRetriesOnStop() {
        startWithLid()
        lid.failDisable = true
        c.update(readings: readings(thermal: .serious))
        c.update(readings: readings(thermal: .serious))
        #expect(c.session?.lidModeActive == true)
        #expect(c.session?.lidModeSuspendedReason == nil)
        #expect(c.attention == .helperUnavailable)
        let n = notifier.posted.filter { $0 == .lidModeSuspended(.helperUnavailable) }.count
        #expect(n == 1)
        let before = lid.disableCalls
        lid.failDisable = false
        c.stop(.user)
        #expect(lid.disableCalls == before + 1)
    }

    @Test func setLidModeOffDisableFailureKeepsLidActive() {
        startWithLid()
        lid.failDisable = true
        c.setLidMode(false)
        #expect(c.session?.lidModeActive == true)
        #expect(c.attention == .helperUnavailable)
    }

    @Test func setLidModeOnWhileActiveIsNoop() {
        startWithLid()
        clock.advance(60)
        c.setLidMode(true)
        #expect(lid.enableCalls == 1)
        #expect(c.session?.lidModeEnabledAt == t0)
    }
}
