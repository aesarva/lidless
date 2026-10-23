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

    @Test func repeatedLidEnableFailureNotifiesOnce() {
        lid.failEnable = true
        startWithLid()
        c.setLidMode(false)
        c.setLidMode(true)
        #expect(lid.enableCalls == 2)
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
        lid.failRecover = true
        c.update(readings: readings())
        c.update(readings: readings())
        #expect(lid.recoverCalls == 2)
        #expect(c.attention == .helperUnavailable)
        #expect(helperUnavailablePosts() == 1)
        c.clearAttention()
        #expect(c.attention == .helperUnavailable)

        lid.failRecover = false
        c.update(readings: readings())
        #expect(c.attention == .helperUnavailable)
        c.clearAttention()
        #expect(c.attention == nil)
    }

    @Test func successfulRecoveryWhileOffKeepsUnrelatedAttention() {
        c.start(.indefinite)
        c.update(readings: readings(level: 10, onBattery: true))
        #expect(c.attention == .lowBattery)
        c.update(readings: readings(level: 10, onBattery: true))
        #expect(c.attention == .lowBattery)
        #expect(lid.recoverCalls == 1)
    }

    @Test func failedRecoveryAfterClearRaisesAgain() {
        lid.failRecover = true
        c.update(readings: readings())
        #expect(c.attention == .helperUnavailable)
        #expect(helperUnavailablePosts() == 1)
        c.clearAttention()
        c.update(readings: readings())
        #expect(c.attention == .helperUnavailable)
        #expect(helperUnavailablePosts() == 1)
    }

    @Test func recoverAtLaunchFailureRaisesAttention() {
        lid.failRecover = true
        c.recoverAtLaunch()
        #expect(lid.recoverCalls == 1)
        #expect(c.attention == .helperUnavailable)
        #expect(helperUnavailablePosts() == 1)
        c.clearAttention()
        #expect(c.attention == .helperUnavailable)
    }

    @Test func helperDidChangeRetriesRecoveryWhileOff() {
        lid.failRecover = true
        c.recoverAtLaunch()
        #expect(c.attention == .helperUnavailable)
        lid.failRecover = false
        c.helperDidChange()
        #expect(lid.recoverCalls == 2)
        c.clearAttention()
        #expect(c.attention == nil)
    }

    @Test func helperDidChangeFailureRaisesAttention() {
        lid.failRecover = true
        c.helperDidChange()
        #expect(lid.recoverCalls == 1)
        #expect(c.attention == .helperUnavailable)
        #expect(helperUnavailablePosts() == 1)
    }

    @Test func helperDidChangeWhileActiveDoesNotRecover() {
        startWithLid()
        c.helperDidChange()
        #expect(lid.recoverCalls == 0)
        #expect(lid.disableCalls == 0)
        #expect(c.session?.lidModeActive == true)
    }

    // MARK: - Lost daemon connection

    @Test func connectionLostReenablesLidMode() {
        startWithLid()
        clock.advance(60)
        c.helperConnectionLost(generation: 1)
        #expect(lid.enableCalls == 2)
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
        #expect(lid.enableCalls == 2)
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
        let before = lid.enableCalls
        c.update(readings: readings(thermal: .serious))
        #expect(lid.enableCalls == before)
        #expect(c.session?.lidModeActive == false)
        #expect(c.session?.lidModeSuspendedReason == .thermal)
        #expect(c.attention == .thermal)
        #expect(notifier.posted.contains(.lidModeSuspended(.thermal)))
        c.update(readings: readings())
        #expect(lid.enableCalls == before)
    }

    @Test func recoveryAfterBatteryLimitStaysSuspended() {
        startWithLid()
        lid.failEnable = true
        c.helperConnectionLost(generation: 1)
        lid.failEnable = false
        clock.advance(240 * 60)
        c.update(readings: readings(onBattery: true, lidClosed: true, since: t0))
        #expect(lid.enableCalls == 2)
        #expect(c.session?.lidModeActive == false)
        #expect(c.session?.lidModeSuspendedReason == .lidOnBatteryLimit)
    }

    @Test func connectionLostWhileHotSuspendsForThermal() {
        startWithLid()
        lid.failDisable = true
        c.update(readings: readings(thermal: .serious))
        #expect(c.session?.lidModeActive == true)
        c.helperConnectionLost(generation: 1)
        #expect(lid.enableCalls == 1)
        #expect(c.session?.lidModeActive == false)
        #expect(c.session?.lidModeSuspendedReason == .thermal)
        #expect(c.attention == .thermal)
    }

    @Test func pollDoesNotRetryOtherSuspensions() {
        startWithLid()
        c.update(readings: readings(thermal: .serious))
        #expect(c.session?.lidModeSuspendedReason == .thermal)
        c.update(readings: readings())
        #expect(lid.enableCalls == 1)
        #expect(c.session?.lidModeActive == false)
    }

    @Test func pollDoesNotRetryWhenLidModeTurnedOff() {
        lid.failEnable = true
        startWithLid()
        c.setLidMode(false)
        lid.failEnable = false
        c.update(readings: readings())
        #expect(lid.enableCalls == 1)
    }

    /// A helper in error would only time out, on the main thread: the poll asks for a
    /// background check instead and calls the helper once it is installed again.
    @Test func pollRetryWaitsForAUsableHelper() {
        var refreshes = 0
        c.onHelperRefreshNeeded = { refreshes += 1 }
        lid.failEnable = true
        startWithLid()
        lid.failEnable = false
        for status in [HelperStatus.notInstalled, .needsApproval, .unsigned] {
            lid.status = status
            c.update(readings: readings())
        }
        #expect(refreshes == 0)
        lid.status = .error("timed out")
        c.update(readings: readings())
        #expect(lid.enableCalls == 1)
        #expect(refreshes == 1)
        lid.status = .installed
        c.update(readings: readings())
        #expect(lid.enableCalls == 2)
        #expect(c.session?.lidModeActive == true)
    }

    /// Turning lid mode on with the helper in error does not call it (that would freeze the
    /// app until the call times out). Unlike the approval wait it warns at once: the wish
    /// waits, a background check is asked for, and lid mode turns on once the helper is
    /// installed again.
    @Test func lidModeWithHelperErrorWarnsAndWaitsForRefresh() {
        var refreshes = 0
        c.onHelperRefreshNeeded = { refreshes += 1 }
        c.start(.indefinite)
        lid.status = .error("timed out")
        c.setLidMode(true)
        #expect(lid.enableCalls == 0)
        #expect(refreshes == 1)
        #expect(c.session?.lidModeActive == false)
        #expect(c.session?.lidModeSuspendedReason == .helperUnavailable)
        #expect(c.attention == .helperUnavailable)
        #expect(helperUnavailablePosts() == 1)
        lid.status = .installed
        c.helperDidChange()
        #expect(lid.enableCalls == 1)
        #expect(c.session?.lidModeActive == true)
        #expect(c.session?.lidModeSuspendedReason == nil)
        // As after any helper failure, the dot goes when the user opens the panel.
        c.clearAttention()
        #expect(c.attention == nil)
        #expect(helperUnavailablePosts() == 1)
    }

    /// The helper stays in error after the user has seen the warning: the next readings
    /// raise it again, as a failed retry always did, still without calling the helper.
    @Test func pollWithHelperErrorWarnsAgainAfterClear() {
        var refreshes = 0
        c.onHelperRefreshNeeded = { refreshes += 1 }
        lid.status = .error("timed out")
        startWithLid()
        c.clearAttention()
        #expect(c.attention == nil)
        c.update(readings: readings())
        #expect(lid.enableCalls == 0)
        #expect(refreshes == 2)
        #expect(c.attention == .helperUnavailable)
        #expect(helperUnavailablePosts() == 2)
    }

    /// A session started (e.g. from the right-click menu) with lid mode wanted and the
    /// helper in error warns at once instead of lighting up as if lid mode were on.
    @Test func startWithLidModeAndHelperErrorWarns() {
        var refreshes = 0
        c.onHelperRefreshNeeded = { refreshes += 1 }
        lid.status = .error("timed out")
        startWithLid()
        #expect(lid.enableCalls == 0)
        #expect(refreshes == 1)
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
        await refresh?.value
        #expect(backend.refreshInfoCalls == 1)
        #expect(backend.setCalls == [true])
        #expect(c.session?.lidModeActive == true)
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
        await refresh?.value
        #expect(backend.setCalls.isEmpty)
        #expect(coordinator.status == .error("timed out"))
        #expect(c.settings.lidModeEnabled)
        #expect(c.session?.lidModeSuspendedReason == .helperUnavailable)
        #expect(c.attention == .helperUnavailable)
        #expect(helperUnavailablePosts() == 1)
    }

    /// Before the user has allowed the helper, turning lid mode on does not call it: lid mode
    /// waits silently and turns on once the helper is usable.
    @Test func lidModeWaitsSilentlyForApproval() {
        for status in [HelperStatus.notInstalled, .needsApproval] {
            let lid = FakeLid()
            let notifier = FakeNotifier()
            let c = SessionController(assertions: assertions, lid: lid, notifier: notifier,
                                      settingsStore: MemorySettingsStore(), clock: clock)
            c.start(.indefinite)
            lid.status = status
            c.setLidMode(true)
            #expect(lid.enableCalls == 0)
            #expect(c.session?.lidModeActive == false)
            #expect(c.session?.lidModeSuspendedReason == .helperUnavailable)
            #expect(notifier.posted.isEmpty)
            #expect(c.attention == nil)
            lid.status = .installed
            c.helperDidChange()
            #expect(lid.enableCalls == 1)
            #expect(c.session?.lidModeActive == true)
            #expect(c.session?.lidModeSuspendedReason == nil)
        }
    }

    @Test func startWithLidModeWaitsSilentlyForApproval() {
        lid.status = .needsApproval
        startWithLid()
        #expect(lid.enableCalls == 0)
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
        #expect(lid.enableCalls == 1)
        lid.status = .installed
        c.helperDidChange()
        #expect(lid.enableCalls == 2)
        #expect(c.session?.lidModeActive == true)
    }

    /// A failed helper removal keeps a safety suspension as it was and acquires nothing.
    @Test func failedRemovalKeepsSafetySuspension() {
        startWithLid()
        c.update(readings: readings(thermal: .serious))
        #expect(c.session?.lidModeSuspendedReason == .thermal)
        let point = c.beginHelperRemoval()
        #expect(c.settings.lidModeEnabled == false)
        c.restoreAfterFailedRemoval(point)
        #expect(c.settings.lidModeEnabled == true)
        #expect(store.stored.lidModeEnabled == true)
        #expect(c.session?.lidModeActive == false)
        #expect(c.session?.lidModeSuspendedReason == .thermal)
        #expect(lid.enableCalls == 1)
    }

    /// Lid mode that was on comes back through the safety-checked retry, keeping its start.
    @Test func failedRemovalReenablesActiveLidMode() {
        startWithLid()
        clock.advance(600)
        let point = c.beginHelperRemoval()
        #expect(lid.disableCalls == 1)
        #expect(c.session?.lidModeActive == false)
        c.restoreAfterFailedRemoval(point)
        #expect(c.session?.lidModeSuspendedReason == .helperUnavailable)
        #expect(c.attention == nil)
        #expect(notifier.posted.isEmpty)
        #expect(lid.enableCalls == 1)
        c.update(readings: readings())
        #expect(lid.enableCalls == 2)
        #expect(c.session?.lidModeActive == true)
        #expect(c.session?.lidModeEnabledAt == t0)
    }

    /// A safety suspension that happened during the removal stays: the restore must not turn
    /// it into a helper wait that the poll would re-acquire.
    @Test func failedRemovalKeepsANewerSafetySuspension() {
        startWithLid()
        lid.failDisable = true
        let point = c.beginHelperRemoval()
        #expect(c.session?.lidModeActive == true)
        lid.failDisable = false
        c.update(readings: readings(thermal: .serious))
        #expect(c.session?.lidModeSuspendedReason == .thermal)
        c.restoreAfterFailedRemoval(point)
        #expect(c.settings.lidModeEnabled == true)
        #expect(c.session?.lidModeSuspendedReason == .thermal)
        c.update(readings: readings())
        #expect(lid.enableCalls == 1)
        #expect(c.session?.lidModeActive == false)
    }

    /// A restore point from an earlier session only brings back the setting.
    @Test func failedRemovalIgnoresAnotherSession() {
        startWithLid()
        let point = c.beginHelperRemoval()
        c.stop(.user)
        clock.advance(60)
        c.start(.indefinite)
        c.restoreAfterFailedRemoval(point)
        #expect(c.settings.lidModeEnabled == true)
        #expect(c.session?.lidModeSuspendedReason == nil)
        c.update(readings: readings())
        #expect(lid.enableCalls == 1)
    }

    /// Choosing another duration during the removal is the same session: lid mode comes back.
    @Test func failedRemovalSurvivesARestart() {
        startWithLid()
        let point = c.beginHelperRemoval()
        clock.advance(600)
        c.restart(.minutes(60))
        #expect(c.session?.startedAt != t0)
        c.restoreAfterFailedRemoval(point)
        #expect(c.session?.lidModeSuspendedReason == .helperUnavailable)
        c.update(readings: readings())
        #expect(lid.enableCalls == 2)
        #expect(c.session?.lidModeActive == true)
        #expect(c.session?.lidModeEnabledAt == t0)
    }

    @Test func failedRemovalWithLidModeOffStaysOff() {
        c.start(.indefinite)
        let point = c.beginHelperRemoval()
        c.restoreAfterFailedRemoval(point)
        #expect(c.settings.lidModeEnabled == false)
        #expect(c.session?.lidModeSuspendedReason == nil)
        c.update(readings: readings())
        #expect(lid.enableCalls == 0)
    }

    /// Loss of an older connection reported after lid mode was re-acquired on a newer one:
    /// ignored, and the hold is still released later.
    @Test func staleConnectionLossAfterReacquireIsIgnored() {
        let backend = FakeBackend()
        let service = LidSleepService(backend: backend)
        let c = SessionController(assertions: assertions, lid: service, notifier: notifier,
                                  settingsStore: store, clock: clock)
        c.settings.lidModeEnabled = true
        c.start(.indefinite)
        backend.generation = 2
        c.setLidMode(false)
        c.setLidMode(true)
        #expect(backend.setCalls == [true, false, true])

        c.helperConnectionLost(generation: 1)
        #expect(backend.setCalls == [true, false, true])
        #expect(c.session?.lidModeActive == true)

        c.update(readings: readings(thermal: .serious))
        #expect(c.session?.lidModeSuspendedReason == .thermal)
        #expect(backend.setCalls == [true, false, true, false])
    }

    @Test func connectionLossThatDoesNotAffectTheHoldIsIgnored() {
        startWithLid()
        lid.lossAffectsHold = false
        lid.failEnable = true
        c.helperConnectionLost(generation: 1)
        #expect(lid.enableCalls == 1)
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
        #expect(lid.enableCalls == 0)
        c.start(.indefinite)
        c.helperConnectionLost(generation: 1)
        #expect(lid.enableCalls == 0)
        #expect(notifier.posted.isEmpty)
    }

    /// A failed disable leaves lid mode active with the setting off: the lost connection
    /// already released it, so it must not be turned back on.
    @Test func connectionLostAfterUserTurnedLidModeOffDoesNotReenable() {
        startWithLid()
        lid.failDisable = true
        c.setLidMode(false)
        #expect(c.session?.lidModeActive == true)
        #expect(c.attention == .helperUnavailable)
        c.helperConnectionLost(generation: 1)
        #expect(lid.enableCalls == 1)
        #expect(lid.lostGenerations == [1])
        #expect(c.session?.lidModeActive == false)
        #expect(c.session?.lidModeSuspendedReason == nil)
        #expect(c.attention == nil)

        lid.failDisable = false
        c.setLidMode(true)
        #expect(lid.enableCalls == 2)
        #expect(c.session?.lidModeActive == true)
    }

    @Test func helperDidChangeRetriesSuspendedLidMode() {
        lid.failEnable = true
        startWithLid()
        #expect(c.session?.lidModeSuspendedReason == .helperUnavailable)
        lid.failEnable = false
        c.helperDidChange()
        #expect(lid.enableCalls == 2)
        #expect(c.session?.lidModeActive == true)
        #expect(lid.recoverCalls == 0)
    }

    @Test func setLidModeOnWhileActiveIsNoop() {
        startWithLid()
        clock.advance(60)
        c.setLidMode(true)
        #expect(lid.enableCalls == 1)
        #expect(c.session?.lidModeEnabledAt == t0)
    }
}
