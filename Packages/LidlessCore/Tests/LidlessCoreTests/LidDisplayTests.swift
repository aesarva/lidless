import Testing
import Foundation
@testable import LidlessCore

/// Closing the lid in closed-lid mode turns the screen off while the Mac keeps running.
@MainActor
struct LidDisplayTests {
    let clock = MutableClock(Date(timeIntervalSince1970: 1_800_000_000))
    let assertions = FakeAssertions()
    let lid = FakeLid()
    let display = FakeDisplay()
    let c: SessionController

    init() {
        c = SessionController(assertions: assertions, lid: lid, notifier: FakeNotifier(),
                              settingsStore: MemorySettingsStore(), clock: clock, display: display)
    }

    func readings(lidClosed: Bool) -> SafetyReadings {
        SafetyReadings(batteryLevel: 80, onBattery: false, thermal: .nominal,
                       lidClosed: lidClosed, lidClosedOnBatterySince: nil, now: clock.now)
    }

    func startWithLid(keepDisplayOn: Bool) {
        c.settings.lidModeEnabled = true
        c.settings.keepDisplayOn = keepDisplayOn
        c.update(readings: readings(lidClosed: false))
        c.start(.indefinite)
    }

    @Test func lidCloseSleepsDisplayAndDropsDisplayAssertion() {
        startWithLid(keepDisplayOn: true)
        c.update(readings: readings(lidClosed: true))
        #expect(display.sleepCalls == 1)
        #expect(assertions.acquired == [true, false])
        #expect(c.session != nil)
        #expect(c.session?.lidModeActive == true)
    }

    @Test func lidCloseWithoutDisplayAssertionOnlySleepsDisplay() {
        startWithLid(keepDisplayOn: false)
        c.update(readings: readings(lidClosed: true))
        #expect(display.sleepCalls == 1)
        #expect(assertions.acquired == [false])
    }

    @Test func lidOpenRestoresDisplayAssertion() {
        startWithLid(keepDisplayOn: true)
        c.update(readings: readings(lidClosed: true))
        c.update(readings: readings(lidClosed: false))
        #expect(assertions.acquired == [true, false, true])
        #expect(display.sleepCalls == 1)
    }

    @Test func repeatedClosedReadingsSleepOnce() {
        startWithLid(keepDisplayOn: false)
        c.update(readings: readings(lidClosed: true))
        c.update(readings: readings(lidClosed: true))
        #expect(display.sleepCalls == 1)
    }

    @Test func externalDisplayKeepsScreensOn() {
        display.external = true
        startWithLid(keepDisplayOn: true)
        c.update(readings: readings(lidClosed: true))
        #expect(display.sleepCalls == 0)
        #expect(assertions.acquired == [true])
    }

    @Test func withoutLidModeNothingHappens() {
        c.update(readings: readings(lidClosed: false))
        c.start(.indefinite)
        c.update(readings: readings(lidClosed: true))
        #expect(display.sleepCalls == 0)
    }

    @Test func displayToggleWhileLidClosedWaitsForOpen() {
        startWithLid(keepDisplayOn: false)
        c.update(readings: readings(lidClosed: true))
        c.setKeepDisplayOn(true)
        #expect(assertions.acquired == [false, false])
        c.update(readings: readings(lidClosed: false))
        #expect(assertions.acquired == [false, false, true])
    }

    @Test func stopWhileLidClosedForgetsHeldDisplay() {
        startWithLid(keepDisplayOn: true)
        c.update(readings: readings(lidClosed: true))
        c.stop(.user)
        c.update(readings: readings(lidClosed: false))
        #expect(assertions.acquired == [true, false])
    }
}
