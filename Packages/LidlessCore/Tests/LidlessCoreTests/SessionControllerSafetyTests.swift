import Testing
import Foundation
@testable import LidlessCore

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

    /// Lets deferred main-actor work (the refresh request) and the helper service's queue run
    /// until `condition` holds, for up to 2 s.
    func until(_ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(2)
        while !condition(), Date() < deadline {
            await Task.yield()
            if !condition() { try? await Task.sleep(nanoseconds: 1_000_000) }
        }
        #expect(condition())
    }

    @Test func startWithLidModeEnables() {
        startWithLid()
        #expect(lid.wanted == [true])
        #expect(lid.acquireCalls == 1)
        #expect(c.session?.lidModeActive == true)
        #expect(c.session?.lidModeEnabledAt == t0)
    }

    @Test func stopDisablesLid() {
        startWithLid()
        c.stop(.user)
        #expect(lid.wanted == [true, false])
    }

    @Test func appQuitDisablesLidMode() {
        startWithLid()
        c.stop(.appQuit)
        #expect(lid.wanted == [true, false])
        #expect(!notifier.posted.contains(.sessionEnded(.appQuit)))
    }

    @Test func repeatedLidEnableFailureNotifiesOnce() {
        lid.failEnable = true
        startWithLid()
        c.setLidMode(false)
        c.setLidMode(true)
        #expect(lid.wanted == [true, false, true])
        #expect(lid.acquireCalls == 2)
        #expect(helperUnavailablePosts() == 1)
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
        #expect(lid.wanted == [true, false])
        #expect(c.attention == .thermal)
        #expect(notifier.posted.contains(.lidModeSuspended(.thermal)))
    }

    /// Starting with the lid setting on while the Mac is already hot: the rules judge the
    /// wish before it is published, so the hold is never taken, not even until the next readings.
    @Test func startWhileHotPausesLidModeWithoutTakingIt() {
        c.update(readings: readings(thermal: .serious))
        startWithLid()
        #expect(c.session != nil)
        #expect(lid.wanted.isEmpty)
        #expect(lid.acquireCalls == 0)
        #expect(c.session?.lidModeActive == false)
        #expect(c.session?.lidModeSuspendedReason == .thermal)
        #expect(c.attention == .thermal)
        #expect(notifier.posted == [.lidModeSuspended(.thermal)])
        // The pause holds, like one of active lid mode: no hold, no second notice.
        c.update(readings: readings(thermal: .serious))
        c.update(readings: readings())
        #expect(lid.acquireCalls == 0)
        #expect(c.session?.lidModeSuspendedReason == .thermal)
        #expect(notifier.posted == [.lidModeSuspended(.thermal)])
    }

    /// The user's own enable while hot: paused for the heat, not wanted. Asking again while
    /// it is still hot shows the pause again without a second notice.
    @Test func manualEnableWhileHotPausesLidModeWithoutTakingIt() {
        c.start(.indefinite)
        c.update(readings: readings(thermal: .serious))
        c.setLidMode(true)
        #expect(c.settings.lidModeEnabled)
        #expect(lid.wanted.isEmpty)
        #expect(lid.acquireCalls == 0)
        #expect(c.session?.lidModeSuspendedReason == .thermal)
        #expect(c.attention == .thermal)
        c.clearAttention()
        c.setLidMode(true)
        #expect(lid.acquireCalls == 0)
        #expect(c.attention == .thermal)
        #expect(notifier.posted == [.lidModeSuspended(.thermal)])
        // Cooled down: the user's next enable takes it.
        c.update(readings: readings())
        c.setLidMode(true)
        #expect(lid.wanted == [true])
        #expect(c.session?.lidModeActive == true)
    }

    /// Enabled while waiting for the helper, the battery time limit is reached before the
    /// helper is allowed: once it is, the hold is not taken.
    @Test func batteryLimitReachedWhileWaitingForTheHelperIsNotTaken() {
        lid.status = .needsApproval
        startWithLid()
        #expect(c.session?.lidModeSuspendedReason == .helperUnavailable)
        clock.advance(240 * 60)
        c.update(readings: readings(onBattery: true, lidClosed: true, since: t0))
        lid.status = .installed
        c.helperDidChange()
        #expect(lid.acquireCalls == 0)
        #expect(c.session?.lidModeActive == false)
        #expect(c.session?.lidModeSuspendedReason == .lidOnBatteryLimit)
        #expect(c.attention == .lidOnBatteryLimit)
        #expect(notifier.posted == [.lidModeSuspended(.lidOnBatteryLimit)])
    }

    /// The user's enable after that pause is judged on a new interval: it is taken.
    @Test func userEnableAfterTheBatteryLimitStartsANewInterval() {
        lid.status = .needsApproval
        startWithLid()
        clock.advance(240 * 60)
        c.update(readings: readings(onBattery: true, lidClosed: true, since: t0))
        c.clearAttention()
        lid.status = .installed
        c.setLidMode(true)
        #expect(lid.acquireCalls == 1)
        #expect(c.session?.lidModeActive == true)
    }

    /// What the lid switch shows in a session: lid mode wanted, held or not. Waiting for the
    /// helper (here while the daemon is checked) counts, so the switch can turn it off.
    @Test func lidModeWaitingForTheHelperIsWanted() {
        #expect(!c.lidModeWanted)
        lid.status = .checking
        startWithLid()
        #expect(c.session?.lidModeActive == false)
        #expect(c.session?.lidModePending == false)
        #expect(c.lidModeWanted)
        #expect(lid.wanted == [true])
        c.setLidMode(false)
        #expect(!c.lidModeWanted)
        #expect(lid.wanted == [true, false])
    }

    /// A safety pause is off on the switch (a tap turns lid mode on again); so is lid mode
    /// during a helper removal, and with no session.
    @Test func lidModePausedOrBeingRemovedIsNotWanted() {
        startWithLid()
        #expect(c.lidModeWanted)
        c.update(readings: readings(thermal: .serious))
        #expect(!c.lidModeWanted)
        #expect(c.settings.lidModeEnabled)
        c.update(readings: readings())
        c.setLidMode(true)
        #expect(c.lidModeWanted)
        lid.holdConfirm = true
        c.beginHelperRemoval { _, _ in }
        #expect(!c.lidModeWanted)
        c.endHelperRemoval()
        c.stop(.user)
        #expect(!c.lidModeWanted)
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
        #expect(lid.wanted == [true, false])
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

    /// The suspension is recorded at once; the failed release leaves a reset pending, which
    /// the poll retries and reports once.
    @Test func suspendDisableFailureSuspendsAndRetriesRelease() {
        startWithLid()
        lid.failDisable = true
        lid.confirmResult = false
        c.update(readings: readings(thermal: .serious))
        c.update(readings: readings(thermal: .serious))
        #expect(c.session?.lidModeActive == false)
        #expect(c.session?.lidModeSuspendedReason == .thermal)
        #expect(c.attention == .helperUnavailable)
        #expect(notifier.posted == [.lidModeSuspended(.thermal), .lidModeSuspended(.helperUnavailable)])
        #expect(lid.wanted == [true, false])
        lid.failDisable = false
        lid.confirmResult = true
        c.update(readings: readings())
        #expect(lid.hold == LidHold())
        c.clearAttention()
        #expect(c.attention == nil)
    }

    /// The switch is off at once; the failed release keeps the warning up until the daemon
    /// confirms it holds nothing.
    @Test func setLidModeOffDisableFailureLeavesResetPending() {
        startWithLid()
        lid.failDisable = true
        c.setLidMode(false)
        #expect(c.session?.lidModeActive == false)
        #expect(c.attention == .helperUnavailable)
        #expect(helperUnavailablePosts() == 1)
        c.clearAttention()
        #expect(c.attention == .helperUnavailable)
    }

    func helperUnavailablePosts() -> Int {
        notifier.posted.filter { $0 == .lidModeSuspended(.helperUnavailable) }.count
    }

    @Test func stopDisableFailurePostsHelperUnavailable() {
        startWithLid()
        lid.failDisable = true
        c.stop(.user)
        #expect(c.state == .off)
        #expect(c.attention == .helperUnavailable)
        #expect(helperUnavailablePosts() == 1)
    }

    @Test func stopDisableFailureKeepsWarningBeforeNextPoll() {
        startWithLid()
        lid.failDisable = true
        c.stop(.user)
        c.clearAttention()
        #expect(c.attention == .helperUnavailable)
    }

    @Test func failedRecoveryWhileOffKeepsWarningUntilRecovered() {
        startWithLid()
        lid.failDisable = true
        c.stop(.user)
        #expect(c.state == .off)
        lid.confirmResult = false
        c.update(readings: readings())
        c.update(readings: readings())
        #expect(lid.confirmCalls == 2)
        #expect(c.attention == .helperUnavailable)
        #expect(helperUnavailablePosts() == 1)
        c.clearAttention()
        #expect(c.attention == .helperUnavailable)

        lid.confirmResult = true
        c.update(readings: readings())
        #expect(c.attention == nil)
        c.update(readings: readings())
        #expect(lid.confirmCalls == 3)
        #expect(helperUnavailablePosts() == 1)
    }

    /// A reset confirmed after an unrelated warning came up leaves that warning alone.
    @Test func successfulRecoveryWhileOffKeepsUnrelatedAttention() {
        startWithLid()
        lid.failDisable = true
        lid.confirmResult = false
        c.setLidMode(false)
        #expect(c.attention == .helperUnavailable)
        lid.failDisable = false
        lid.confirmResult = true
        c.update(readings: readings(level: 10, onBattery: true))
        #expect(c.state == .off)
        #expect(lid.confirmCalls == 1)
        #expect(c.attention == .lowBattery)
        c.update(readings: readings(level: 10, onBattery: true))
        #expect(c.attention == .lowBattery)
        #expect(lid.confirmCalls == 1)
    }

    @Test func failedRecoveryAfterClearRaisesAgain() {
        startWithLid()
        lid.failDisable = true
        c.stop(.user)
        #expect(c.attention == .helperUnavailable)
        #expect(helperUnavailablePosts() == 1)
        c.clearAttention()
        lid.confirmResult = false
        c.update(readings: readings())
        #expect(c.attention == .helperUnavailable)
        #expect(helperUnavailablePosts() == 1)
    }

    @Test func helperDidChangeRetriesRecoveryWhileOff() {
        startWithLid()
        lid.failDisable = true
        c.stop(.user)
        #expect(c.attention == .helperUnavailable)
        lid.failDisable = false
        c.helperDidChange()
        #expect(lid.confirmCalls == 1)
        #expect(lid.hold == LidHold())
        c.clearAttention()
        #expect(c.attention == nil)
    }

    @Test func helperDidChangeFailureRaisesAttention() {
        startWithLid()
        lid.failDisable = true
        c.stop(.user)
        c.clearAttention()
        lid.confirmResult = false
        c.helperDidChange()
        #expect(lid.confirmCalls == 1)
        #expect(c.attention == .helperUnavailable)
        #expect(helperUnavailablePosts() == 1)
    }

    @Test func helperDidChangeWhileActiveDoesNotRecover() {
        startWithLid()
        c.helperDidChange()
        #expect(lid.confirmCalls == 0)
        #expect(lid.wanted == [true])
        #expect(c.session?.lidModeActive == true)
    }

    // MARK: - Lost daemon connection

    @Test func connectionLostReenablesLidMode() {
        startWithLid()
        clock.advance(60)
        c.helperConnectionLost(generation: 1)
        #expect(lid.acquireCalls == 2)
        #expect(lid.wanted == [true])
        #expect(c.session?.lidModeActive == true)
        // The battery time limit keeps counting from the original enable.
        #expect(c.session?.lidModeEnabledAt == t0)
        #expect(notifier.posted.isEmpty)
        #expect(c.attention == nil)
        #expect(lid.lostGenerations == [1])
    }

    @Test func connectionLostAndReenableFailsSuspendsOnce() {
        startWithLid()
        lid.failEnable = true
        c.helperConnectionLost(generation: 1)
        c.helperConnectionLost(generation: 1)
        #expect(lid.acquireCalls == 2)
        #expect(c.session?.lidModeActive == false)
        #expect(c.session?.lidModeSuspendedReason == .helperUnavailable)
        #expect(c.attention == .helperUnavailable)
        #expect(helperUnavailablePosts() == 1)
        #expect(c.settings.lidModeEnabled == true)
    }

    @Test func pollRetriesHelperSuspendedLidMode() {
        startWithLid()
        lid.failEnable = true
        c.helperConnectionLost(generation: 1)
        c.update(readings: readings())
        #expect(c.session?.lidModeActive == false)
        #expect(helperUnavailablePosts() == 1)

        lid.failEnable = false
        clock.advance(60)
        c.update(readings: readings())
        #expect(c.session?.lidModeActive == true)
        #expect(c.session?.lidModeSuspendedReason == nil)
        // Automatic recovery keeps the battery time limit counting from the user's enable.
        #expect(c.session?.lidModeEnabledAt == t0)
    }

    /// A retry the safety rules would suspend right away becomes that suspension instead.
    @Test func pollRetryTurnsIntoSafetySuspension() {
        startWithLid()
        lid.failEnable = true
        c.helperConnectionLost(generation: 1)
        lid.failEnable = false
        let before = lid.acquireCalls
        c.update(readings: readings(thermal: .serious))
        #expect(lid.acquireCalls == before)
        #expect(c.session?.lidModeActive == false)
        #expect(c.session?.lidModeSuspendedReason == .thermal)
        #expect(c.attention == .thermal)
        #expect(notifier.posted.contains(.lidModeSuspended(.thermal)))
        c.update(readings: readings())
        #expect(lid.acquireCalls == before)
    }

    @Test func recoveryAfterBatteryLimitStaysSuspended() {
        startWithLid()
        lid.failEnable = true
        c.helperConnectionLost(generation: 1)
        lid.failEnable = false
        clock.advance(240 * 60)
        c.update(readings: readings(onBattery: true, lidClosed: true, since: t0))
        #expect(lid.acquireCalls == 2)
        #expect(c.session?.lidModeActive == false)
        #expect(c.session?.lidModeSuspendedReason == .lidOnBatteryLimit)
    }

    /// The thermal suspension is recorded even though the release failed; the daemon lets go
    /// when the connection drops, and nothing is taken again.
    @Test func connectionLostWhileHotSuspendsForThermal() {
        startWithLid()
        lid.failDisable = true
        lid.confirmResult = false
        c.update(readings: readings(thermal: .serious))
        #expect(c.session?.lidModeActive == false)
        #expect(c.session?.lidModeSuspendedReason == .thermal)
        c.helperConnectionLost(generation: 1)
        #expect(lid.acquireCalls == 1)
        #expect(lid.hold == LidHold())
        #expect(c.session?.lidModeActive == false)
        #expect(c.session?.lidModeSuspendedReason == .thermal)
        #expect(c.attention == .helperUnavailable)
        lid.confirmResult = true
        c.update(readings: readings())
        // The reset is confirmed; the thermal suspension still holds and shows again.
        #expect(c.attention == .thermal)
        #expect(c.session?.lidModeSuspendedReason == .thermal)
        #expect(lid.acquireCalls == 1)
    }

    /// The rules would suspend held lid mode when the connection drops (here the thermal rule
    /// was just turned on): suspended before the service could take the hold again.
    @Test func connectionLossWhileRulesBlockDoesNotReacquire() {
        c.settings.safety.thermalRuleEnabled = false
        startWithLid()
        c.update(readings: readings(thermal: .serious))
        #expect(c.session?.lidModeActive == true)
        c.settings.safety.thermalRuleEnabled = true
        c.helperConnectionLost(generation: 1)
        #expect(lid.wanted == [true, false])
        #expect(lid.acquireCalls == 1)
        #expect(c.session?.lidModeSuspendedReason == .thermal)
        #expect(c.attention == .thermal)
        #expect(notifier.posted == [.lidModeSuspended(.thermal)])
    }

    @Test func pollDoesNotRetryOtherSuspensions() {
        startWithLid()
        c.update(readings: readings(thermal: .serious))
        #expect(c.session?.lidModeSuspendedReason == .thermal)
        c.update(readings: readings())
        #expect(lid.acquireCalls == 1)
        #expect(c.session?.lidModeActive == false)
    }

    @Test func pollDoesNotRetryWhenLidModeTurnedOff() {
        lid.failEnable = true
        startWithLid()
        c.setLidMode(false)
        lid.failEnable = false
        c.update(readings: readings())
        #expect(lid.acquireCalls == 1)
    }

    /// A helper in error would only time out, on the main thread: the poll asks for a
    /// background check instead and calls the helper once it is installed again.
    @Test func pollRetryWaitsForAUsableHelper() async {
        var refreshes = 0
        c.onHelperRefreshNeeded = { refreshes += 1 }
        lid.failEnable = true
        startWithLid()
        lid.failEnable = false
        for status in [HelperStatus.notInstalled, .needsApproval, .checking, .unsigned] {
            lid.status = status
            c.update(readings: readings())
        }
        #expect(refreshes == 0)
        lid.status = .error("timed out")
        c.update(readings: readings())
        #expect(lid.acquireCalls == 1)
        await until { refreshes == 1 }
        lid.status = .installed
        c.update(readings: readings())
        #expect(lid.acquireCalls == 2)
        #expect(c.session?.lidModeActive == true)
    }

    /// Turning lid mode on with the helper in error does not call it (that would freeze the
    /// app until the call times out). Unlike the approval wait it warns at once: the wish
    /// waits, a background check is asked for, and lid mode turns on once the helper is
    /// installed again.
    @Test func lidModeWithHelperErrorWarnsAndWaitsForRefresh() async {
        var refreshes = 0
        c.onHelperRefreshNeeded = { refreshes += 1 }
        c.start(.indefinite)
        lid.status = .error("timed out")
        c.setLidMode(true)
        #expect(lid.acquireCalls == 0)
        await until { refreshes == 1 }
        #expect(c.session?.lidModeActive == false)
        #expect(c.session?.lidModeSuspendedReason == .helperUnavailable)
        #expect(c.attention == .helperUnavailable)
        #expect(helperUnavailablePosts() == 1)
        lid.status = .installed
        c.helperDidChange()
        #expect(lid.acquireCalls == 1)
        #expect(c.session?.lidModeActive == true)
        #expect(c.session?.lidModeSuspendedReason == nil)
        // As after any helper failure, the dot goes when the user opens the panel.
        c.clearAttention()
        #expect(c.attention == nil)
        #expect(helperUnavailablePosts() == 1)
    }

    /// The helper stays in error after the user has seen the warning: the next readings
    /// raise it again, as a failed retry always did, still without calling the helper.
    @Test func pollWithHelperErrorWarnsAgainAfterClear() async {
        var refreshes = 0
        c.onHelperRefreshNeeded = { refreshes += 1 }
        lid.status = .error("timed out")
        startWithLid()
        await until { refreshes == 1 }
        c.clearAttention()
        #expect(c.attention == nil)
        c.update(readings: readings())
        #expect(lid.acquireCalls == 0)
        await until { refreshes == 2 }
        #expect(c.attention == .helperUnavailable)
        #expect(helperUnavailablePosts() == 2)
    }

    /// The refresh request runs after `enableLidMode` has finished: a refresh that finds the
    /// helper installed at once (the coordinator calls `onBecameInstalled` synchronously)
    /// must not take lid mode from inside the call that just gave up on it.
    @Test func refreshRequestNeverReentersEnable() async {
        var requests = 0
        var acquireCallsAtRequest: Int?
        c.onHelperRefreshNeeded = { [c, lid] in
            requests += 1
            acquireCallsAtRequest = lid.acquireCalls
            lid.status = .installed
            c.helperDidChange()
        }
        c.start(.indefinite)
        lid.status = .error("timed out")
        c.setLidMode(true)
        // Not yet: the request is deferred, so nothing ran inside setLidMode.
        #expect(requests == 0)
        #expect(lid.acquireCalls == 0)
        await until { requests == 1 }
        #expect(acquireCallsAtRequest == 0)
        #expect(lid.acquireCalls == 1)
        #expect(c.session?.lidModeActive == true)
        #expect(c.session?.lidModeSuspendedReason == nil)
    }

    /// Several requests in one turn ask the coordinator once.
    @Test func refreshRequestsInOneTurnAreCoalesced() async {
        var requests = 0
        c.onHelperRefreshNeeded = { requests += 1 }
        c.start(.indefinite)
        lid.status = .error("timed out")
        c.setLidMode(true)
        c.update(readings: readings())
        c.update(readings: readings())
        await until { requests >= 1 }
        for _ in 0..<10 { await Task.yield() }
        #expect(requests == 1)
    }

    /// A session started (e.g. from the right-click menu) with lid mode wanted and the
    /// helper in error warns at once instead of lighting up as if lid mode were on.
    @Test func startWithLidModeAndHelperErrorWarns() async {
        var refreshes = 0
        c.onHelperRefreshNeeded = { refreshes += 1 }
        lid.status = .error("timed out")
        startWithLid()
        #expect(lid.acquireCalls == 0)
        await until { refreshes == 1 }
        #expect(c.session?.lidModeSuspendedReason == .helperUnavailable)
        #expect(c.attention == .helperUnavailable)
        #expect(helperUnavailablePosts() == 1)
    }

    /// The app's wiring: the switch makes no daemon call, the coordinator's background
    /// refresh finds the daemon installed again and lid mode is taken once.
    @Test func lidModeWithHelperErrorAppliesAfterBackgroundRefresh() async {
        let backend = FakeBackend()
        backend.stubStatus = .error("timed out")
        let coordinator = HelperCoordinator(backend: backend, scheduler: ManualPollScheduler(), lidModeHeld: { false })
        let c = SessionController(assertions: assertions, lid: LidSleepService(backend: backend),
                                  notifier: notifier, settingsStore: MemorySettingsStore(), clock: clock)
        var refresh: Task<Void, Never>?
        c.onHelperRefreshNeeded = { refresh = coordinator.refresh() }
        coordinator.onBecameInstalled = { c.helperDidChange() }
        c.start(.indefinite)
        backend.statusAfterRefresh = .installed
        c.setLidMode(true)
        #expect(backend.setCalls.isEmpty)
        #expect(c.session?.lidModeActive == false)
        await until { refresh != nil }
        await refresh?.value
        #expect(backend.refreshInfoCalls == 1)
        await until { c.session?.lidModeActive == true }
        #expect(backend.setCalls == [true])
    }

    /// The refresh still fails: lid mode keeps waiting with the warning up and the daemon is
    /// never called.
    @Test func lidModeWithHelperErrorStaysWaitingWhenRefreshFails() async {
        let backend = FakeBackend()
        backend.stubStatus = .error("timed out")
        let coordinator = HelperCoordinator(backend: backend, scheduler: ManualPollScheduler(), lidModeHeld: { false })
        let c = SessionController(assertions: assertions, lid: LidSleepService(backend: backend),
                                  notifier: notifier, settingsStore: MemorySettingsStore(), clock: clock)
        var refresh: Task<Void, Never>?
        c.onHelperRefreshNeeded = { refresh = coordinator.refresh() }
        coordinator.onBecameInstalled = { c.helperDidChange() }
        c.start(.indefinite)
        c.setLidMode(true)
        await until { refresh != nil }
        await refresh?.value
        #expect(backend.setCalls.isEmpty)
        #expect(coordinator.status == .error("timed out"))
        #expect(c.settings.lidModeEnabled)
        #expect(c.session?.lidModeSuspendedReason == .helperUnavailable)
        #expect(c.attention == .helperUnavailable)
        #expect(helperUnavailablePosts() == 1)
    }

    /// Before the user has allowed the helper, or before the daemon of this registration
    /// answered, turning lid mode on does not call it: lid mode waits silently and turns on
    /// once the helper is usable.
    @Test func lidModeWaitsSilentlyForApproval() {
        for status in [HelperStatus.notInstalled, .needsApproval, .checking] {
            let lid = FakeLid()
            let notifier = FakeNotifier()
            let c = SessionController(assertions: assertions, lid: lid, notifier: notifier,
                                      settingsStore: MemorySettingsStore(), clock: clock)
            c.start(.indefinite)
            lid.status = status
            c.setLidMode(true)
            #expect(lid.acquireCalls == 0)
            #expect(c.session?.lidModeActive == false)
            #expect(c.session?.lidModeSuspendedReason == .helperUnavailable)
            #expect(notifier.posted.isEmpty)
            #expect(c.attention == nil)
            lid.status = .installed
            c.helperDidChange()
            #expect(lid.acquireCalls == 1)
            #expect(c.session?.lidModeActive == true)
            #expect(c.session?.lidModeSuspendedReason == nil)
        }
    }

    @Test func startWithLidModeWaitsSilentlyForApproval() {
        lid.status = .needsApproval
        startWithLid()
        #expect(lid.acquireCalls == 0)
        #expect(c.session?.lidModeSuspendedReason == .helperUnavailable)
        #expect(notifier.posted.isEmpty)
        #expect(c.attention == nil)
    }

    /// Switching the helper off in Login Items mid-session drops the hold: that is a loss the
    /// user must hear about once, even though the helper now waits for approval.
    @Test func lostHoldWhileWaitingForApprovalRaisesAttention() {
        startWithLid()
        lid.status = .needsApproval
        c.helperConnectionLost(generation: 1)
        c.helperConnectionLost(generation: 1)
        #expect(c.session?.lidModeActive == false)
        #expect(c.session?.lidModeSuspendedReason == .helperUnavailable)
        #expect(c.attention == .helperUnavailable)
        #expect(notifier.posted == [.lidModeSuspended(.helperUnavailable)])
        #expect(lid.acquireCalls == 1)
        lid.status = .installed
        c.helperDidChange()
        #expect(lid.acquireCalls == 2)
        #expect(c.session?.lidModeActive == true)
    }

    /// Begins a helper removal and returns its restore point (`FakeLid` answers at once).
    func beginRemoval() -> LidModeRestorePoint {
        var point: LidModeRestorePoint?
        c.beginHelperRemoval { p, _ in point = p }
        return point!
    }

    /// A failed helper removal keeps a safety suspension as it was and acquires nothing.
    @Test func failedRemovalKeepsSafetySuspension() {
        startWithLid()
        c.update(readings: readings(thermal: .serious))
        #expect(c.session?.lidModeSuspendedReason == .thermal)
        let point = beginRemoval()
        #expect(c.settings.lidModeEnabled == false)
        c.restoreAfterFailedRemoval(point)
        c.endHelperRemoval()
        #expect(c.settings.lidModeEnabled == true)
        #expect(store.stored.lidModeEnabled == true)
        #expect(c.session?.lidModeActive == false)
        #expect(c.session?.lidModeSuspendedReason == .thermal)
        #expect(lid.acquireCalls == 1)
    }

    /// A safety suspension newer than the restore point stays: the restore must not turn it
    /// into a helper wait that the poll would re-acquire.
    @Test func restoreKeepsANewerSafetySuspension() {
        startWithLid()
        let point = LidModeRestorePoint(sessionID: c.session?.id, lidModeEnabled: true,
                                        wasActive: true, wasPending: false, suspendedReason: nil)
        c.update(readings: readings(thermal: .serious))
        #expect(c.session?.lidModeSuspendedReason == .thermal)
        c.restoreAfterFailedRemoval(point)
        #expect(c.session?.lidModeSuspendedReason == .thermal)
        c.update(readings: readings())
        #expect(lid.acquireCalls == 1)
        #expect(c.session?.lidModeActive == false)
        #expect(c.session?.lidModeSuspendedReason == .thermal)
    }

    /// Lid mode that was on comes back when the removal ends (not on a poll before), keeping
    /// its start.
    @Test func failedRemovalReenablesActiveLidMode() {
        startWithLid()
        clock.advance(600)
        let point = beginRemoval()
        #expect(lid.wanted == [true, false])
        #expect(c.session?.lidModeActive == false)
        c.restoreAfterFailedRemoval(point)
        #expect(c.session?.lidModeSuspendedReason == .helperUnavailable)
        #expect(c.attention == nil)
        #expect(notifier.posted.isEmpty)
        c.update(readings: readings())
        #expect(lid.acquireCalls == 1)
        c.endHelperRemoval()
        #expect(lid.acquireCalls == 2)
        #expect(c.session?.lidModeActive == true)
        #expect(c.session?.lidModeEnabledAt == t0)
    }

    /// Lid mode is off at once even when the release during the removal fails, and the
    /// removal stops; restored, lid mode comes back only through the safety check, which
    /// turns a hot Mac into a thermal suspension that stays.
    @Test func failedRemovalKeepsANewerSafetySuspension() {
        startWithLid()
        lid.failDisable = true
        lid.confirmResult = false
        var results: [Bool] = []
        c.beginHelperRemoval { point, ok in
            results.append(ok)
            c.restoreAfterFailedRemoval(point)
        }
        #expect(results == [false])
        #expect(c.session?.lidModeActive == false)
        lid.failDisable = false
        #expect(c.settings.lidModeEnabled == true)
        #expect(c.session?.lidModeSuspendedReason == .helperUnavailable)
        c.update(readings: readings(thermal: .serious))
        c.endHelperRemoval()
        #expect(c.session?.lidModeSuspendedReason == .thermal)
        c.update(readings: readings())
        #expect(lid.acquireCalls == 1)
        #expect(c.session?.lidModeActive == false)
        #expect(c.session?.lidModeSuspendedReason == .thermal)
    }

    /// The safety check at the end uses the latest readings even when none came after the
    /// restore.
    @Test func endOfRemovalChecksSafetyBeforeWanting() {
        startWithLid()
        let point = beginRemoval()
        c.update(readings: readings(thermal: .serious))
        c.restoreAfterFailedRemoval(point)
        c.endHelperRemoval()
        #expect(lid.wanted == [true, false])
        #expect(c.session?.lidModeSuspendedReason == .thermal)
        #expect(lid.acquireCalls == 1)
    }

    /// A restore point from an earlier session only brings back the setting; the running
    /// session follows it when the removal ends, with a new battery-limit interval.
    @Test func failedRemovalIgnoresAnotherSession() {
        startWithLid()
        let point = beginRemoval()
        c.stop(.user)
        clock.advance(60)
        c.start(.indefinite)
        c.restoreAfterFailedRemoval(point)
        #expect(c.settings.lidModeEnabled == true)
        #expect(c.session?.lidModeSuspendedReason == nil)
        #expect(lid.acquireCalls == 1)
        c.endHelperRemoval()
        #expect(lid.acquireCalls == 2)
        #expect(c.session?.lidModeEnabledAt == clock.now)
    }

    /// Choosing another duration during the removal is the same session: lid mode comes back.
    @Test func failedRemovalSurvivesARestart() {
        startWithLid()
        let point = beginRemoval()
        clock.advance(600)
        c.restart(.minutes(60))
        #expect(c.session?.startedAt != t0)
        c.restoreAfterFailedRemoval(point)
        #expect(c.session?.lidModeSuspendedReason == .helperUnavailable)
        c.endHelperRemoval()
        #expect(lid.acquireCalls == 2)
        #expect(c.session?.lidModeActive == true)
        #expect(c.session?.lidModeEnabledAt == t0)
    }

    @Test func failedRemovalWithLidModeOffStaysOff() {
        c.start(.indefinite)
        let point = beginRemoval()
        c.restoreAfterFailedRemoval(point)
        c.endHelperRemoval()
        #expect(c.settings.lidModeEnabled == false)
        #expect(c.session?.lidModeSuspendedReason == nil)
        c.update(readings: readings())
        #expect(lid.acquireCalls == 0)
    }

    /// Loss of an older connection reported after lid mode was re-acquired on a newer one:
    /// ignored, and the hold is still released later.
    @Test func staleConnectionLossAfterReacquireIsIgnored() async {
        let backend = FakeBackend()
        let service = LidSleepService(backend: backend)
        let c = SessionController(assertions: assertions, lid: service, notifier: notifier,
                                  settingsStore: store, clock: clock)
        c.settings.lidModeEnabled = true
        c.start(.indefinite)
        await until { service.hold == LidHold(held: true, pending: false, failure: nil) }
        backend.generation = 2
        c.setLidMode(false)
        // The service's confirmed release, not just the daemon seeing the call.
        await until { service.hold == LidHold() }
        c.setLidMode(true)
        await until { service.hold == LidHold(held: true, pending: false, failure: nil) }
        #expect(c.session?.lidModeActive == true)
        #expect(backend.setCalls == [true, false, true])

        c.helperConnectionLost(generation: 1)
        #expect(c.session?.lidModeActive == true)

        c.update(readings: readings(thermal: .serious))
        #expect(c.session?.lidModeSuspendedReason == .thermal)
        await until { backend.setCalls == [true, false, true, false] }
    }

    @Test func connectionLossThatDoesNotAffectTheHoldIsIgnored() {
        startWithLid()
        lid.lossAffectsHold = false
        lid.failEnable = true
        c.helperConnectionLost(generation: 1)
        #expect(lid.acquireCalls == 1)
        #expect(c.session?.lidModeActive == true)
        #expect(notifier.posted.isEmpty)
    }

    /// The user's own enable starts a new battery-limit interval even when it fails, so the
    /// automatic retry after it is not suspended at once by the old interval.
    @Test func explicitEnableStartsANewIntervalEvenWhenItFails() {
        startWithLid()
        clock.advance(240 * 60)
        c.update(readings: readings(onBattery: true, lidClosed: true, since: t0))
        #expect(c.session?.lidModeSuspendedReason == .lidOnBatteryLimit)

        lid.failEnable = true
        c.setLidMode(true)
        #expect(c.session?.lidModeSuspendedReason == .helperUnavailable)
        #expect(c.session?.lidModeEnabledAt == clock.now)

        lid.failEnable = false
        clock.advance(15)
        c.update(readings: readings(onBattery: true, lidClosed: true, since: t0))
        #expect(c.session?.lidModeActive == true)
        #expect(c.session?.lidModeSuspendedReason == nil)
    }

    @Test func connectionLostWithoutLidModeDoesNothing() {
        c.helperConnectionLost(generation: 1)
        #expect(lid.acquireCalls == 0)
        c.start(.indefinite)
        c.helperConnectionLost(generation: 1)
        #expect(lid.acquireCalls == 0)
        #expect(notifier.posted.isEmpty)
    }

    /// A failed disable leaves a reset pending with lid mode off: the lost connection released
    /// the hold, so it is not turned back on, and the next readings confirm the reset.
    @Test func connectionLostAfterUserTurnedLidModeOffDoesNotReenable() {
        startWithLid()
        lid.failDisable = true
        c.setLidMode(false)
        #expect(c.session?.lidModeActive == false)
        #expect(c.attention == .helperUnavailable)
        c.helperConnectionLost(generation: 1)
        #expect(lid.acquireCalls == 1)
        #expect(lid.lostGenerations == [1])
        #expect(lid.wanted == [true, false])
        #expect(c.session?.lidModeActive == false)
        #expect(c.session?.lidModeSuspendedReason == nil)
        c.update(readings: readings())
        #expect(c.attention == nil)

        lid.failDisable = false
        c.setLidMode(true)
        #expect(lid.acquireCalls == 2)
        #expect(c.session?.lidModeActive == true)
    }

    @Test func helperDidChangeRetriesSuspendedLidMode() {
        lid.failEnable = true
        startWithLid()
        #expect(c.session?.lidModeSuspendedReason == .helperUnavailable)
        lid.failEnable = false
        c.helperDidChange()
        #expect(lid.acquireCalls == 2)
        #expect(c.session?.lidModeActive == true)
        #expect(lid.confirmCalls == 0)
    }

    @Test func setLidModeOnWhileActiveIsNoop() {
        startWithLid()
        clock.advance(60)
        c.setLidMode(true)
        #expect(lid.acquireCalls == 1)
        #expect(c.session?.lidModeEnabledAt == t0)
    }
}
