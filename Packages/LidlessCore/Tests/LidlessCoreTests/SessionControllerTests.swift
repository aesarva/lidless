import Testing
import Foundation
@testable import LidlessCore

@MainActor
struct SessionControllerTests {
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

    func endingSoonCount() -> Int {
        notifier.posted.filter { if case .endingSoon = $0 { return true } else { return false } }.count
    }

    @Test func startAcquiresAndStopReleases() {
        #expect(c.start(.minutes(60)))
        #expect(assertions.acquired == [false])
        #expect(c.session?.endsAt == t0.addingTimeInterval(3600))
        c.stop(.user)
        #expect(assertions.released == 1)
        #expect(c.state == .off)
        #expect(notifier.posted.isEmpty)
    }

    @Test func timerExpiresEvenAfterOversleep() {
        c.start(.minutes(15))
        clock.advance(7200)
        c.tick()
        #expect(c.state == .off)
        #expect(notifier.posted.last == .sessionEnded(.timerExpired))
    }

    @Test func endingSoonOnceAt300s() {
        c.start(.minutes(15))
        clock.advance(599); c.tick()
        #expect(endingSoonCount() == 0)
        clock.advance(1); c.tick()
        #expect(notifier.posted == [.endingSoon(endsAt: t0.addingTimeInterval(900))])
        c.tick()
        #expect(endingSoonCount() == 1)
    }

    @Test func noEndingSoonForShortSession() {
        c.start(.until(t0.addingTimeInterval(240)))
        clock.advance(10); c.tick()
        #expect(endingSoonCount() == 0)
    }

    @Test func extendPushesEndAndRearmsWarning() {
        c.start(.minutes(15))
        clock.advance(700); c.tick()
        #expect(endingSoonCount() == 1)
        c.extend(byMinutes: 30)
        #expect(c.session?.endsAt == t0.addingTimeInterval(2700))
        #expect(notifier.cancelEndingSoonCount == 1)
        clock.advance(1700); c.tick()
        #expect(endingSoonCount() == 2)
    }

    @Test func extendIndefiniteIsNoOp() {
        c.start(.indefinite)
        c.extend(byMinutes: 30)
        #expect(c.session?.endsAt == nil)
        #expect(notifier.cancelEndingSoonCount == 0)
    }

    @Test func restartReplacesDuration() {
        c.start(.minutes(15))
        clock.advance(600)
        c.restart(.minutes(180))
        #expect(c.session?.startedAt == t0.addingTimeInterval(600))
        #expect(c.session?.endsAt == t0.addingTimeInterval(600 + 10800))
        #expect(c.session.map { $0.endsAt!.timeIntervalSince($0.startedAt) } == 10800)
        #expect(assertions.acquired == [false])
    }

    @Test func startWhileActiveIsNoOp() {
        c.settings.lidModeEnabled = true
        #expect(c.start(.minutes(15)))
        let before = c.session
        clock.advance(100)
        #expect(!c.start(.minutes(60)))
        #expect(c.session == before)
        #expect(lid.enableCalls == 1)
        #expect(assertions.acquired == [false])
    }

    @Test func restartWhenOffStarts() {
        c.restart(.minutes(60))
        #expect(c.session?.endsAt == t0.addingTimeInterval(3600))
    }

    @Test func toggleUsesDefaultDuration() {
        c.settings.defaultDuration = .indefinite
        c.toggle()
        #expect(c.session != nil)
        #expect(c.session?.endsAt == nil)
        c.toggle()
        #expect(c.state == .off)
    }

    @Test func displayToggleReacquires() {
        c.start(.indefinite)
        c.setKeepDisplayOn(true)
        #expect(assertions.acquired == [false, true])
        #expect(c.settings.keepDisplayOn)
        #expect(store.stored.keepDisplayOn)
        #expect(c.session?.keepDisplayOn == true)
    }

    @Test func assertionFailureDoesNotStart() {
        assertions.failNext = true
        #expect(!c.start(.minutes(15)))
        #expect(c.state == .off)
        #expect(notifier.posted.count == 1)
        guard case .assertionFailed = notifier.posted[0] else {
            Issue.record("expected assertionFailed"); return
        }
    }

    @Test func lowBatteryBlocksStart() {
        c.update(readings: SafetyReadings(batteryLevel: 10, onBattery: true, thermal: .nominal,
                                          lidClosed: false, lidClosedOnBatterySince: nil, now: t0))
        #expect(c.startBlock == .lowBattery(threshold: 20))
        #expect(!c.start(.minutes(15)))
        #expect(c.state == .off)
        #expect(c.startBlock == .lowBattery(threshold: 20))
        #expect(assertions.acquired.isEmpty)
    }

    @Test func recoverAtLaunchCallsLidAndOptionallyStarts() {
        c.recoverAtLaunch()
        #expect(lid.recoverCalls == 1)
        #expect(c.state == .off)
        c.startOnLaunchIfEnabled()
        #expect(c.state == .off)
        c.settings.startSessionOnLaunch = true
        c.recoverAtLaunch()
        #expect(lid.recoverCalls == 2)
        #expect(c.state == .off)
        c.startOnLaunchIfEnabled()
        #expect(c.session != nil)
    }

    @Test func startOnLaunchSeesFirstReadings() {
        c.settings.startSessionOnLaunch = true
        c.recoverAtLaunch()
        c.update(readings: SafetyReadings(batteryLevel: 5, onBattery: true, thermal: .nominal,
                                          lidClosed: false, lidClosedOnBatterySince: nil, now: t0))
        c.startOnLaunchIfEnabled()
        #expect(c.state == .off)
        #expect(c.startBlock == .lowBattery(threshold: 20))
    }

    @Test func lidModeEnabledOnStartAndDisabledOnStop() {
        c.settings.lidModeEnabled = true
        c.start(.indefinite)
        #expect(lid.enableCalls == 1)
        #expect(c.session?.lidModeActive == true)
        #expect(c.session?.lidModeEnabledAt == t0)
        c.stop(.user)
        #expect(lid.disableCalls == 1)
    }
}
