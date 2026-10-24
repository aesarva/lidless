import Testing
import Foundation
@testable import LidlessCore

/// Settings → Helper → Remove: the daemon is unregistered only after it confirmed with a
/// fresh answer that it owns nothing; until the removal ends, lid mode is not wanted.
@MainActor
struct SessionHelperRemovalTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let clock: MutableClock
    let lid = FakeLid()
    let notifier = FakeNotifier()
    let c: SessionController

    init() {
        clock = MutableClock(t0)
        c = SessionController(assertions: FakeAssertions(), lid: lid, notifier: notifier,
                              settingsStore: MemorySettingsStore(), clock: clock)
    }

    func startWithLid() {
        c.settings.lidModeEnabled = true
        c.start(.indefinite)
    }

    /// Lets the helper service's queue run until `condition` holds, for up to 2 s.
    func until(_ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(2)
        while !condition(), Date() < deadline {
            await Task.yield()
            if !condition() { try? await Task.sleep(nanoseconds: 1_000_000) }
        }
        #expect(condition())
    }

    @Test func removalProceedsAfterConfirmedRelease() {
        startWithLid()
        lid.confirmResult = true
        var results: [Bool] = []
        c.beginHelperRemoval { _, ok in results.append(ok) }
        #expect(lid.wanted == [true, false])
        #expect(lid.confirmCalls == 1)
        #expect(results == [true])
        #expect(c.settings.lidModeEnabled == false)
    }

    /// The release the daemon answered with an error leaves the hold: not removed.
    @Test func removalStopsWhenReleaseFails() {
        startWithLid()
        lid.autoConfirm = false
        lid.holdConfirm = true
        lid.confirmResult = false
        var results: [Bool] = []
        c.beginHelperRemoval { _, ok in results.append(ok) }
        lid.deliver(held: true, failure: "disable failed")
        #expect(results.isEmpty)
        lid.deliverConfirm()
        #expect(results == [false])
    }

    /// The daemon's fresh "owns nothing" also settles a reset left pending by a failed release.
    @Test func confirmedRemovalSettlesAPendingReset() {
        startWithLid()
        lid.failDisable = true
        var results: [Bool] = []
        c.beginHelperRemoval { _, ok in results.append(ok) }
        #expect(results == [true])
        #expect(notifier.posted == [.lidModeSuspended(.helperUnavailable)])
        #expect(c.attention == nil)
        c.clearAttention()
        #expect(c.attention == nil)
    }

    @Test func removalStopsWhenDaemonStillOwns() {
        startWithLid()
        lid.confirmResult = false
        var results: [Bool] = []
        c.beginHelperRemoval { _, ok in results.append(ok) }
        #expect(lid.confirmCalls == 1)
        #expect(results == [false])
    }

    /// No hold of this app's own is no proof: disablesleep may be left over from before.
    @Test func removalWithoutLocalHoldStillAsksDaemon() {
        c.start(.indefinite)
        var results: [Bool] = []
        c.beginHelperRemoval { _, ok in results.append(ok) }
        #expect(lid.wanted.isEmpty)
        #expect(lid.confirmCalls == 1)
        #expect(results == [true])
    }

    @Test func secondRemovalWhileRunningIgnored() {
        startWithLid()
        lid.holdConfirm = true
        var results: [Bool] = []
        c.beginHelperRemoval { _, ok in results.append(ok) }
        c.beginHelperRemoval { _, ok in results.append(ok) }
        #expect(lid.confirmCalls == 1)
        lid.deliverConfirm()
        #expect(results == [true])
        // Still running until it ends, even after the answer.
        c.beginHelperRemoval { _, ok in results.append(ok) }
        #expect(lid.confirmCalls == 1)
        #expect(results == [true])
        c.endHelperRemoval()
        c.beginHelperRemoval { _, ok in results.append(ok) }
        #expect(lid.confirmCalls == 2)
        lid.deliverConfirm()
        #expect(results == [true, true])
    }

    @Test func noAcquireDuringRemoval() {
        c.start(.indefinite)
        lid.holdConfirm = true
        c.beginHelperRemoval { _, _ in }
        c.setLidMode(true)
        c.update(readings: SafetyReadings(batteryLevel: 80, onBattery: false, thermal: .nominal,
                                          lidClosed: false, lidClosedOnBatterySince: nil, now: clock.now))
        c.helperDidChange()
        #expect(lid.wanted.isEmpty)
        #expect(lid.acquireCalls == 0)
        #expect(c.session?.lidModeActive == false)
        c.endHelperRemoval()
        #expect(lid.wanted == [true])
        #expect(c.session?.lidModeActive == true)
    }

    /// Lid mode on its way when the removal began comes back as it was, with its start.
    @Test func failedRemovalRestoresPendingEnable() throws {
        lid.autoConfirm = false
        startWithLid()
        #expect(c.session?.lidModePending == true)
        clock.advance(600)
        lid.confirmResult = false
        var point: LidModeRestorePoint?
        var results: [Bool] = []
        c.beginHelperRemoval { p, ok in
            point = p
            results.append(ok)
        }
        #expect(results == [false])
        #expect(point?.wasPending == true)
        #expect(c.settings.lidModeEnabled == false)
        #expect(lid.wanted == [true, false])
        c.restoreAfterFailedRemoval(try #require(point))
        c.endHelperRemoval()
        #expect(c.settings.lidModeEnabled == true)
        #expect(lid.wanted == [true, false, true])
        #expect(c.session?.lidModePending == true)
        #expect(c.session?.lidModeEnabledAt == t0)
    }

    /// With the helper service: the answer comes from a fresh `info` asked only after the
    /// release has reached the daemon.
    @Test func removalWaitsForTheQueuedRelease() async {
        let backend = FakeBackend()
        backend.stubInfo = HelperInfo(version: "0.4.0", build: "1", sleepDisabled: false, owned: false)
        let service = LidSleepService(backend: backend)
        let c = SessionController(assertions: FakeAssertions(), lid: service, notifier: notifier,
                                  settingsStore: MemorySettingsStore(), clock: clock)
        c.settings.lidModeEnabled = true
        c.start(.indefinite)
        await until { service.hold == LidHold(held: true, pending: false, failure: nil) }
        backend.holdSets = true
        var results: [Bool] = []
        c.beginHelperRemoval { _, ok in results.append(ok) }
        // The release waits in the daemon: the check queued behind it has not run.
        await until { backend.setCalls == [true, false] }
        #expect(backend.freshInfoCalls == 0)
        #expect(results.isEmpty)
        backend.releaseSet()
        await until { results == [true] }
        #expect(backend.freshInfoCalls == 1)
    }
}
