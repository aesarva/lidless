import Testing
import Foundation
@testable import LidlessCore

/// Closed-lid mode as a wanted state: the controller sets the wish, the helper service
/// answers later (`FakeLid` with `autoConfirm` off, answered by hand with `deliver`).
@MainActor
struct SessionLidHoldTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let clock: MutableClock
    let lid = FakeLid()
    let notifier = FakeNotifier()
    let display = FakeDisplay()
    let c: SessionController

    init() {
        clock = MutableClock(t0)
        lid.autoConfirm = false
        c = SessionController(assertions: FakeAssertions(), lid: lid, notifier: notifier,
                              settingsStore: MemorySettingsStore(), clock: clock, display: display)
    }

    func readings(onBattery: Bool = false, thermal: ThermalLevel = .nominal,
                  lidClosed: Bool = false, since: Date? = nil) -> SafetyReadings {
        SafetyReadings(batteryLevel: 80, onBattery: onBattery, thermal: thermal,
                       lidClosed: lidClosed, lidClosedOnBatterySince: since, now: clock.now)
    }

    func helperUnavailablePosts() -> Int {
        notifier.posted.filter { $0 == .lidModeSuspended(.helperUnavailable) }.count
    }

    /// A session with lid mode turned on and the acquisition still on its way.
    func startPending() {
        c.start(.indefinite)
        c.setLidMode(true)
    }

    // MARK: - Stopping while the acquisition is on its way

    @Test func stopDuringPendingEnableReleases() {
        startPending()
        c.stop(.user)
        #expect(lid.wanted == [true, false])
        lid.deliver(held: true)
        #expect(c.session == nil)
    }

    @Test func timerAndSafetyStopDuringPendingEnableRelease() {
        c.start(.minutes(15))
        c.setLidMode(true)
        clock.advance(900)
        c.tick()
        #expect(c.state == .off)
        #expect(lid.wanted == [true, false])

        startPending()
        c.stop(.safety(.lowBattery))
        #expect(lid.wanted == [true, false, true, false])
    }

    // MARK: - Safety rules on a pending acquisition

    @Test func safetyBlockDuringPendingEnable() {
        startPending()
        #expect(lid.wanted == [true])
        c.update(readings: readings(thermal: .serious))
        #expect(c.session?.lidModeSuspendedReason == .thermal)
        #expect(c.attention == .thermal)
        #expect(notifier.posted == [.lidModeSuspended(.thermal)])
        #expect(lid.wanted == [true, false])
        lid.deliver(held: true)
        #expect(c.session?.lidModeActive == false)
        #expect(c.session?.lidModePending == false)
    }

    /// Cooling down does not bring a suspended lid mode back: only the user can, as for
    /// lid mode that was active.
    @Test func coolingAfterBlockedPendingStaysPaused() {
        startPending()
        c.update(readings: readings(thermal: .serious))
        lid.deliver(held: false)
        c.update(readings: readings())
        #expect(lid.wanted == [true, false])
        #expect(c.session?.lidModeSuspendedReason == .thermal)
        #expect(notifier.posted == [.lidModeSuspended(.thermal)])
    }

    @Test func batteryLimitDuringPendingEnableStaysPaused() {
        startPending()
        clock.advance(240 * 60)
        c.update(readings: readings(onBattery: true, lidClosed: true, since: t0))
        #expect(c.session?.lidModeSuspendedReason == .lidOnBatteryLimit)
        #expect(notifier.posted == [.lidModeSuspended(.lidOnBatteryLimit)])
        #expect(lid.wanted == [true, false])
        c.update(readings: readings())
        #expect(lid.wanted == [true, false])
        #expect(c.session?.lidModeSuspendedReason == .lidOnBatteryLimit)
    }

    // MARK: - Confirmed holds

    @Test func heldAppliedOnlyWhileWanted() {
        startPending()
        c.setLidMode(false)
        lid.deliver(held: true)
        #expect(c.session?.lidModeActive == false)
    }

    @Test func rapidOffOnKeepsHold() {
        startPending()
        c.setLidMode(false)
        c.setLidMode(true)
        lid.deliver(held: true)
        #expect(lid.wanted == [true, false, true])
        #expect(c.session?.lidModeActive == true)
    }

    @Test func pendingShownUntilConfirmed() {
        startPending()
        #expect(c.session?.lidModePending == true)
        #expect(c.session?.lidModeActive == false)
        lid.deliver(held: true)
        #expect(c.session?.lidModePending == false)
        #expect(c.session?.lidModeActive == true)
        #expect(c.session?.lidModeSuspendedReason == nil)
    }

    /// The hold is confirmed with the lid already closed: the screen goes dark now, not at
    /// the next close.
    @Test func closedLidAtConfirmationSleepsDisplay() {
        startPending()
        c.update(readings: readings(lidClosed: true))
        #expect(display.sleepCalls == 0)
        lid.deliver(held: true)
        #expect(display.sleepCalls == 1)
        c.update(readings: readings(lidClosed: true))
        #expect(display.sleepCalls == 1)
    }

    @Test func closedLidAtConfirmationKeepsExternalDisplayOn() {
        display.external = true
        startPending()
        c.update(readings: readings(lidClosed: true))
        lid.deliver(held: true)
        #expect(display.sleepCalls == 0)
    }

    // MARK: - Failed releases

    @Test func failedReleaseKeepsRecoveryUntilFreshConfirm() {
        startPending()
        lid.deliver(held: true)
        c.setLidMode(false)
        #expect(c.session?.lidModeActive == false)
        lid.deliver(held: true, failure: "x")
        #expect(c.session?.lidModeActive == false)
        #expect(c.attention == .helperUnavailable)
        #expect(helperUnavailablePosts() == 1)

        lid.confirmResult = false
        c.update(readings: readings())
        #expect(lid.confirmCalls == 1)
        #expect(c.attention == .helperUnavailable)
        c.clearAttention()
        #expect(c.attention == .helperUnavailable)

        lid.confirmResult = true
        c.update(readings: readings())
        #expect(lid.confirmCalls == 2)
        #expect(c.attention == nil)
        #expect(helperUnavailablePosts() == 1)
    }

    @Test func staleConfirmIgnoredAfterReenable() {
        startPending()
        lid.deliver(held: true)
        c.setLidMode(false)
        lid.deliver(held: true, failure: "x")
        lid.holdConfirm = true
        lid.confirmResult = false
        c.update(readings: readings())
        #expect(lid.confirmCalls == 1)
        c.setLidMode(true)
        lid.deliverConfirm()
        #expect(lid.wanted == [true, false, true])
        #expect(c.settings.lidModeEnabled)
    }

    @Test func staleTrueConfirmDoesNotClearNewRecovery() {
        startPending()
        lid.deliver(held: true)
        c.setLidMode(false)
        lid.deliver(held: true, failure: "x")
        lid.holdConfirm = true
        c.update(readings: readings())
        c.setLidMode(true)
        lid.deliver(held: true)
        c.setLidMode(false)
        lid.deliver(held: true, failure: "y")
        lid.confirmResult = true
        lid.deliverConfirm()
        #expect(c.attention == .helperUnavailable)
        c.clearAttention()
        #expect(c.attention == .helperUnavailable)
    }

    /// While a session runs too, a failed release is retried by the poll.
    @Test func pollRetriesAFailedRelease() {
        startPending()
        lid.deliver(held: true)
        c.setLidMode(false)
        lid.deliver(held: true, failure: "x")
        lid.autoConfirm = true
        c.update(readings: readings())
        #expect(lid.releaseCalls == 1)
        #expect(lid.hold == LidHold())
        #expect(lid.wanted == [true, false])
    }

    /// Lid mode held again after a failed release: the pending reset is moot, and the warning
    /// goes when the user has seen it.
    @Test func reacquiredHoldClearsPendingReset() {
        startPending()
        lid.deliver(held: true)
        c.setLidMode(false)
        lid.deliver(held: true, failure: "x")
        c.clearAttention()
        #expect(c.attention == .helperUnavailable)
        c.setLidMode(true)
        lid.deliver(held: true)
        #expect(c.session?.lidModeActive == true)
        c.clearAttention()
        #expect(c.attention == nil)
        #expect(lid.confirmCalls == 0)
    }

    // MARK: - Helper not usable yet

    /// A build without a Team ID cannot have the helper: lid mode waits like the approval,
    /// without a warning at every session.
    @Test func unsignedWaitsQuietly() {
        let lid = FakeLid()
        lid.status = .unsigned
        let c = SessionController(assertions: FakeAssertions(), lid: lid, notifier: notifier,
                                  settingsStore: MemorySettingsStore(), clock: clock)
        c.settings.lidModeEnabled = true
        c.start(.indefinite)
        c.update(readings: readings())
        #expect(notifier.posted.isEmpty)
        #expect(c.attention == nil)
        #expect(c.session?.lidModeSuspendedReason == .helperUnavailable)
        #expect(c.session?.lidModeActive == false)
        #expect(lid.acquireCalls == 0)
    }

    /// The daemon of this registration has not answered yet: wait for it quietly.
    @Test func checkingWaitsQuietly() {
        let lid = FakeLid()
        lid.status = .checking
        let c = SessionController(assertions: FakeAssertions(), lid: lid, notifier: notifier,
                                  settingsStore: MemorySettingsStore(), clock: clock)
        c.settings.lidModeEnabled = true
        c.start(.indefinite)
        c.update(readings: readings())
        #expect(notifier.posted.isEmpty)
        #expect(c.attention == nil)
        #expect(c.session?.lidModeSuspendedReason == .helperUnavailable)
        #expect(lid.acquireCalls == 0)
        lid.status = .installed
        c.helperDidChange()
        #expect(c.session?.lidModeActive == true)
        #expect(c.session?.lidModeSuspendedReason == nil)
    }

    // MARK: - Lost connection

    /// A re-registration takes the old daemon (and the hold) away while the replacement is
    /// unregistered or being checked: wait quietly and take the hold again once it is verified.
    @Test func lossDuringReregistrationWaitsQuietly() {
        for status in [HelperStatus.checking, .notInstalled] {
            let lid = FakeLid()
            let notifier = FakeNotifier()
            let c = SessionController(assertions: FakeAssertions(), lid: lid, notifier: notifier,
                                      settingsStore: MemorySettingsStore(), clock: clock)
            c.settings.lidModeEnabled = true
            c.start(.indefinite)
            #expect(c.session?.lidModeActive == true)
            lid.status = status
            c.helperConnectionLost(generation: 1)
            #expect(c.session?.lidModeActive == false)
            #expect(c.session?.lidModeSuspendedReason == .helperUnavailable)
            #expect(notifier.posted.isEmpty)
            #expect(c.attention == nil)
            #expect(lid.wanted == [true])
            c.update(readings: readings())
            #expect(notifier.posted.isEmpty)

            lid.status = .installed
            c.helperDidChange()
            #expect(c.session?.lidModeActive == true)
            #expect(c.session?.lidModeSuspendedReason == nil)
            #expect(lid.acquireCalls == 2)
            #expect(notifier.posted.isEmpty)
        }
    }

    /// With the helper still verified the service takes the hold again by itself; the
    /// switch shows it on its way, nothing is reported.
    @Test func lossWithVerifiedHelperReacquiresQuietly() {
        startPending()
        lid.deliver(held: true)
        c.helperConnectionLost(generation: 1)
        #expect(c.session?.lidModeActive == false)
        #expect(c.session?.lidModePending == true)
        #expect(c.session?.lidModeSuspendedReason == nil)
        lid.deliver(held: true)
        #expect(c.session?.lidModeActive == true)
        #expect(notifier.posted.isEmpty)
        #expect(c.attention == nil)
    }

    /// A real failure from a verified daemon is still reported.
    @Test func failedReacquireAfterLossWarns() {
        startPending()
        lid.deliver(held: true)
        c.helperConnectionLost(generation: 1)
        lid.deliver(held: false, failure: "x")
        #expect(c.session?.lidModeSuspendedReason == .helperUnavailable)
        #expect(c.attention == .helperUnavailable)
        #expect(helperUnavailablePosts() == 1)
    }

    // MARK: - Real service

    /// Waiting for the helper, the poll neither shows lid mode on its way (the switch would
    /// blink) nor sends anything; a helper in error asks for one background check per poll.
    @Test func waitingForTheHelperNeverShowsPending() async {
        for status in [HelperStatus.needsApproval, .notInstalled, .checking, .unsigned, .error("x")] {
            let backend = FakeBackend()
            backend.stubStatus = status
            let service = LidSleepService(backend: backend)
            let notifier = FakeNotifier()
            let c = SessionController(assertions: FakeAssertions(), lid: service, notifier: notifier,
                                      settingsStore: MemorySettingsStore(), clock: clock)
            var refreshes = 0
            c.onHelperRefreshNeeded = { refreshes += 1 }
            c.settings.lidModeEnabled = true
            c.start(.indefinite)
            #expect(c.session?.lidModePending == false)
            await flush(service)
            for poll in 1...3 {
                c.update(readings: readings())
                #expect(c.session?.lidModePending == false)
                await flush(service)
                #expect(c.session?.lidModePending == false)
                #expect(c.session?.lidModeSuspendedReason == .helperUnavailable)
                if case .error = status {
                    await until { refreshes == poll + 1 }
                } else {
                    #expect(refreshes == 0)
                }
            }
            #expect(backend.setCalls.isEmpty)
            if case .error = status {
                #expect(refreshes == 4)
                #expect(notifier.posted == [.lidModeSuspended(.helperUnavailable)])
            } else {
                #expect(notifier.posted.isEmpty)
            }
        }
    }

    /// Turning lid mode off returns at once while the daemon is slow to answer.
    @Test func releaseDoesNotWaitForTheDaemon() async {
        let backend = FakeBackend()
        let service = LidSleepService(backend: backend)
        let c = SessionController(assertions: FakeAssertions(), lid: service,
                                  notifier: notifier, settingsStore: MemorySettingsStore(), clock: clock)
        c.settings.lidModeEnabled = true
        c.start(.indefinite)
        await until { c.session?.lidModeActive == true }
        backend.holdSets = true
        c.setLidMode(false)
        #expect(c.session?.lidModeActive == false)
        await until { backend.setCalls == [true, false] }
        c.stop(.user)
        #expect(c.state == .off)
        backend.holdSets = false
        backend.releaseSet()
        var confirmed = false
        // Queued behind the release: it has been answered once this is.
        service.confirmReleased { _ in confirmed = true }
        await until { confirmed }
        #expect(backend.setCalls == [true, false])
        #expect(notifier.posted.isEmpty)
        #expect(c.attention == nil)
    }

    /// Lets the service's queue and its answers, and deferred main-actor work, run.
    func flush(_ service: LidSleepService) async {
        var done = false
        service.confirmReleased { _ in done = true }
        await until { done }
        await Task.yield()
    }

    func until(_ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(2)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        #expect(condition())
    }
}
