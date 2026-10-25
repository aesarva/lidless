import Testing
import Foundation
@testable import LidlessCore

/// A session on air carries over an update relaunch (spec §4).
@MainActor
struct SessionResumeTests {
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

    /// Saved 5 s ago by the previous copy, for a session started 10 min before.
    func snapshot(endsAt: Date? = nil, keepDisplayOn: Bool = false, lidModeActive: Bool = false,
                  pending: Bool = false, suspended: SafetyReason? = nil, enabledAt: Date? = nil,
                  savedAt: Date? = nil) -> ResumeSnapshot {
        ResumeSnapshot(session: Session(startedAt: t0 - 600, endsAt: endsAt, keepDisplayOn: keepDisplayOn,
                                        lidModeActive: lidModeActive, lidModePending: pending,
                                        lidModeEnabledAt: enabledAt, lidModeSuspendedReason: suspended),
                       savedAt: savedAt ?? t0 - 5)
    }

    // MARK: - snapshot

    @Test func snapshotNilWithoutSession() {
        #expect(c.snapshot(now: t0) == nil)
    }

    @Test func snapshotCopiesSession() {
        c.settings.lidModeEnabled = true
        c.start(.minutes(30))
        let s = c.snapshot(now: t0 + 1)
        #expect(s?.savedAt == t0 + 1 && s?.startedAt == t0 && s?.endsAt == t0 + 1800)
        #expect(s?.lidModeActive == true && s?.lidModeEnabledAt == t0)
    }

    // MARK: - resume

    @Test func resumeRestoresTimedSession() {
        #expect(c.resume(snapshot(endsAt: t0 + 900, keepDisplayOn: true)))
        #expect(c.session?.startedAt == t0 - 600)
        #expect(c.session?.endsAt == t0 + 900)
        #expect(c.session?.keepDisplayOn == true)
        #expect(assertions.acquired == [true])
    }

    @Test func resumeKeepsSafetySuspension() {
        c.settings.lidModeEnabled = true
        #expect(c.resume(snapshot(suspended: .thermal, enabledAt: t0 - 300)))
        c.update(readings: readings())
        #expect(lid.acquireCalls == 0)
        #expect(lid.wanted.isEmpty)
        #expect(c.session?.lidModeSuspendedReason == .thermal)
        #expect(c.session?.lidModeActive == false)
        // Shown again, not notified again.
        #expect(c.attention == .thermal)
        #expect(notifier.posted.isEmpty)
    }

    @Test func resumeReenablesLidModeThroughSafetyCheck() {
        c.settings.lidModeEnabled = true
        #expect(c.resume(snapshot(lidModeActive: true, enabledAt: t0 - 300)))
        // Not wanted before the safety rules have seen readings.
        #expect(lid.wanted.isEmpty)
        #expect(c.session?.lidModeSuspendedReason == .helperUnavailable)
        c.update(readings: readings())
        #expect(lid.acquireCalls == 1)
        #expect(c.session?.lidModeActive == true)
        #expect(c.session?.lidModeEnabledAt == t0 - 300)

        // Blocked: closed on battery past the limit, counted from the original start.
        let lid2 = FakeLid()
        let c2 = SessionController(assertions: FakeAssertions(), lid: lid2, notifier: FakeNotifier(),
                                   settingsStore: MemorySettingsStore(), clock: clock)
        c2.settings.lidModeEnabled = true
        let enabledAt = t0 - 241 * 60
        #expect(c2.resume(snapshot(lidModeActive: true, enabledAt: enabledAt)))
        c2.update(readings: readings(onBattery: true, lidClosed: true, since: enabledAt))
        #expect(lid2.acquireCalls == 0)
        #expect(lid2.wanted.isEmpty)
        #expect(c2.session?.lidModeSuspendedReason == .lidOnBatteryLimit)
        #expect(c2.session?.lidModeActive == false)
    }

    @Test func resumeReenablesLidModeWaitingForHelper() {
        c.settings.lidModeEnabled = true
        #expect(c.resume(snapshot(pending: true, enabledAt: t0 - 300)))
        c.update(readings: readings())
        #expect(lid.acquireCalls == 1)
        #expect(c.session?.lidModeActive == true)
        #expect(c.session?.lidModeEnabledAt == t0 - 300)
    }

    /// Readings already at hand (at launch they are fresh): judged and enabled at once.
    @Test func resumeWithReadingsChecksLidModeAtOnce() {
        c.settings.lidModeEnabled = true
        c.update(readings: readings())
        #expect(c.resume(snapshot(lidModeActive: true, enabledAt: t0 - 300)))
        #expect(lid.acquireCalls == 1)
        #expect(c.session?.lidModeActive == true)
        #expect(c.session?.lidModeEnabledAt == t0 - 300)
    }

    @Test func resumeWithBlockingReadingsSuspendsAtOnce() {
        c.settings.lidModeEnabled = true
        c.update(readings: readings(thermal: .serious))
        #expect(c.resume(snapshot(lidModeActive: true, enabledAt: t0 - 300)))
        #expect(lid.acquireCalls == 0)
        #expect(lid.wanted.isEmpty)
        #expect(c.session?.lidModeSuspendedReason == .thermal)
        #expect(c.attention == .thermal)
    }

    /// The helper is not verified yet at launch: lid mode waits for it, then comes back through
    /// the same safety-checked path, keeping its start.
    @Test func resumedLidModeWaitsForHelper() {
        lid.status = .checking
        c.settings.lidModeEnabled = true
        #expect(c.resume(snapshot(lidModeActive: true, enabledAt: t0 - 300)))
        c.update(readings: readings())
        #expect(lid.acquireCalls == 0)
        #expect(c.session?.lidModeSuspendedReason == .helperUnavailable)
        lid.status = .installed
        c.helperDidChange()
        #expect(lid.acquireCalls == 1)
        #expect(c.session?.lidModeActive == true)
        #expect(c.session?.lidModeEnabledAt == t0 - 300)
    }

    /// Saved between the wish and the service's first answer (neither on, on its way nor
    /// suspended): treated as on its way, re-wanted only after the safety check.
    @Test func resumeWithUnansweredLidWishWaitsForSafetyCheck() {
        c.settings.lidModeEnabled = true
        #expect(c.resume(snapshot(enabledAt: t0 - 300)))
        #expect(lid.wanted.isEmpty)
        #expect(lid.acquireCalls == 0)
        #expect(c.session?.lidModeSuspendedReason == .helperUnavailable)
        #expect(c.session?.lidModeEnabledAt == t0 - 300)
        c.update(readings: readings())
        #expect(lid.acquireCalls == 1)
        #expect(c.session?.lidModeActive == true)
        #expect(c.session?.lidModeEnabledAt == t0 - 300)
    }

    @Test func resumeWithUnansweredLidWishBlockedBySafety() {
        c.settings.lidModeEnabled = true
        #expect(c.resume(snapshot(enabledAt: t0 - 300)))
        c.update(readings: readings(thermal: .serious))
        #expect(lid.acquireCalls == 0)
        #expect(lid.wanted.isEmpty)
        #expect(c.session?.lidModeSuspendedReason == .thermal)
    }

    /// The real launch: readings at hand, the helper not verified yet. Wanted only after the
    /// safety check on those readings; turned on by `helperDidChange`, keeping its start.
    @Test func resumeAtLaunchWaitsForHelperThenTurnsOn() {
        lid.status = .checking
        c.settings.lidModeEnabled = true
        c.update(readings: readings())
        #expect(c.resume(snapshot(lidModeActive: true, enabledAt: t0 - 300)))
        #expect(lid.acquireCalls == 0)
        #expect(c.session?.lidModeSuspendedReason == .helperUnavailable)
        lid.status = .installed
        c.helperDidChange()
        #expect(lid.acquireCalls == 1)
        #expect(c.session?.lidModeActive == true)
        #expect(c.session?.lidModeEnabledAt == t0 - 300)
    }

    /// Readings that block arrive before the helper is verified: suspended for that reason,
    /// and the helper's arrival does not turn it on.
    @Test func resumeAtLaunchBlockedBeforeHelperArrives() {
        lid.status = .checking
        c.settings.lidModeEnabled = true
        c.update(readings: readings())
        #expect(c.resume(snapshot(lidModeActive: true, enabledAt: t0 - 300)))
        c.update(readings: readings(thermal: .serious))
        #expect(c.session?.lidModeSuspendedReason == .thermal)
        lid.status = .installed
        c.helperDidChange()
        #expect(lid.acquireCalls == 0)
        #expect(c.session?.lidModeActive == false)
        #expect(lid.wanted.last != true)
    }

    /// The previous copy's quit cancelled the ending-soon notice: it comes again, once.
    @Test func resumeRepostsEndingSoon() {
        #expect(c.resume(snapshot(endsAt: t0 + 120)))
        c.tick()
        c.tick()
        #expect(notifier.posted == [.endingSoon(endsAt: t0 + 120)])
    }

    /// The setting was turned off meanwhile: the session comes back without lid mode.
    @Test func resumeWithLidSettingOffLeavesLidModeOff() {
        #expect(c.resume(snapshot(lidModeActive: true, enabledAt: t0 - 300)))
        c.update(readings: readings())
        #expect(lid.wanted.isEmpty)
        #expect(c.session?.lidModeSuspendedReason == nil)
        #expect(c.session?.lidModeActive == false)
    }

    @Test func resumeBlockedByLowBattery() {
        c.update(readings: readings(level: 10, onBattery: true))
        #expect(!c.resume(snapshot()))
        #expect(c.session == nil)
        #expect(c.startBlock == .lowBattery(threshold: 20))
        #expect(assertions.acquired.isEmpty)
    }

    @Test func resumeIgnoredWhileOnAir() {
        c.start(.indefinite)
        #expect(!c.resume(snapshot(endsAt: t0 + 900)))
        #expect(c.session?.startedAt == t0)
    }

    // MARK: - launch

    @Test func launchResumesInsteadOfStartOnLaunch() {
        c.settings.startSessionOnLaunch = true
        c.settings.defaultDuration = .minutes(60)
        c.launch(resuming: snapshot(endsAt: t0 + 900))
        #expect(c.session?.startedAt == t0 - 600)
        #expect(c.session?.endsAt == t0 + 900)
        #expect(assertions.acquired.count == 1)
    }

    @Test func missingSnapshotFallsBackToStartOnLaunch() {
        c.settings.startSessionOnLaunch = true
        c.launch(resuming: nil)
        #expect(c.session?.startedAt == t0)
    }

    @Test func staleSnapshotFallsBack() {
        c.settings.startSessionOnLaunch = true
        c.launch(resuming: snapshot(savedAt: t0 - ResumeSnapshot.maxAge - 1))
        #expect(c.session?.startedAt == t0)
    }

    @Test func expiredSnapshotFallsBack() {
        c.settings.startSessionOnLaunch = true
        c.launch(resuming: snapshot(endsAt: t0 - 1))
        #expect(c.session?.startedAt == t0)
    }

    @Test func unusableSnapshotWithoutStartOnLaunchStaysOff() {
        c.launch(resuming: snapshot(endsAt: t0 - 1))
        #expect(c.session == nil)
    }
}
