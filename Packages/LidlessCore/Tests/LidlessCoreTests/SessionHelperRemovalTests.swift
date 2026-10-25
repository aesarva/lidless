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

    func readings() -> SafetyReadings {
        SafetyReadings(batteryLevel: 80, onBattery: false, thermal: .nominal,
                       lidClosed: false, lidClosedOnBatterySince: nil, now: clock.now)
    }

    /// A controller over the real helper service; `marker`: the daemon's ownership marker.
    func serviceController(_ backend: FakeBackend, marker: MemoryOwnershipStore = MemoryOwnershipStore())
        -> (SessionController, LidSleepService) {
        let service = LidSleepService(backend: backend, markerAbsent: { !marker.exists() })
        let c = SessionController(assertions: FakeAssertions(), lid: service, notifier: notifier,
                                  settingsStore: MemorySettingsStore(), clock: clock)
        return (c, service)
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
        #expect(lid.removalConfirmCalls == 1)
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
        // No reset pending any more: the next poll does not ask the daemon again.
        c.update(readings: readings())
        #expect(lid.confirmCalls == 0)
    }

    /// A release that failed earlier, with lid mode already unwanted, is sent again before
    /// the check, so a second Remove can succeed.
    @Test func removalRetriesAFailedRelease() {
        startWithLid()
        lid.failDisable = true
        c.setLidMode(false)
        #expect(lid.hold.failure != nil)
        #expect(lid.releaseCalls == 1)
        lid.failDisable = false
        lid.holdConfirm = true
        var results: [Bool] = []
        c.beginHelperRemoval { _, ok in results.append(ok) }
        #expect(lid.releaseCalls == 2)
        #expect(lid.hold == LidHold())
        lid.deliverConfirm()
        #expect(results == [true])
    }

    @Test func removalStopsWhenDaemonStillOwns() {
        startWithLid()
        lid.confirmResult = false
        var results: [Bool] = []
        c.beginHelperRemoval { _, ok in results.append(ok) }
        #expect(lid.removalConfirmCalls == 1)
        #expect(results == [false])
    }

    /// No hold of this app's own is no proof: disablesleep may be left over from before.
    @Test func removalWithoutLocalHoldStillAsksDaemon() {
        c.start(.indefinite)
        var results: [Bool] = []
        c.beginHelperRemoval { _, ok in results.append(ok) }
        #expect(lid.wanted.isEmpty)
        #expect(lid.removalConfirmCalls == 1)
        #expect(results == [true])
    }

    @Test func secondRemovalWhileRunningIgnored() {
        startWithLid()
        lid.holdConfirm = true
        var results: [Bool] = []
        c.beginHelperRemoval { _, ok in results.append(ok) }
        c.beginHelperRemoval { _, ok in results.append(ok) }
        #expect(lid.removalConfirmCalls == 1)
        lid.deliverConfirm()
        #expect(results == [true])
        // Still running until it ends, even after the answer.
        c.beginHelperRemoval { _, ok in results.append(ok) }
        #expect(lid.removalConfirmCalls == 1)
        #expect(results == [true])
        c.endHelperRemoval()
        c.beginHelperRemoval { _, ok in results.append(ok) }
        #expect(lid.removalConfirmCalls == 2)
        lid.deliverConfirm()
        #expect(results == [true, true])
    }

    @Test func noAcquireDuringRemoval() {
        c.start(.indefinite)
        lid.holdConfirm = true
        c.beginHelperRemoval { _, _ in }
        c.setLidMode(true)
        c.update(readings: readings())
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
        let (c, service) = serviceController(backend)
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

    /// With the helper service: the release fails and the daemon still owns disablesleep.
    @Test func removalRefusedWhenTheDaemonStillOwns() async {
        let backend = FakeBackend()
        backend.stubInfo = HelperInfo(version: "0.4.0", build: "1", sleepDisabled: true, owned: true)
        let (c, service) = serviceController(backend)
        c.settings.lidModeEnabled = true
        c.start(.indefinite)
        await until { service.hold == LidHold(held: true, pending: false, failure: nil) }
        backend.failNextSet = .commandFailed("pmset failed")
        var results: [Bool] = []
        c.beginHelperRemoval { _, ok in results.append(ok) }
        await until { results == [false] }
        #expect(backend.setCalls == [true, false])
        #expect(backend.freshInfoCalls == 1)
    }

    /// A verified daemon that does not answer is no confirmation.
    @Test func removalRefusedWhenTheDaemonDoesNotAnswer() async {
        let backend = FakeBackend()
        backend.freshInfoError = .timedOut
        let (c, _) = serviceController(backend)
        c.start(.indefinite)
        var results: [Bool] = []
        c.beginHelperRemoval { _, ok in results.append(ok) }
        await until { results == [false] }
        #expect(backend.freshInfoCalls == 1)
    }

    /// A daemon waiting for approval cannot answer: the ownership marker decides.
    @Test func removalWaitingForApprovalFollowsTheMarker() async {
        for markerPresent in [true, false] {
            let backend = FakeBackend()
            backend.stubStatus = .needsApproval
            let (c, _) = serviceController(backend, marker: MemoryOwnershipStore(exists: markerPresent))
            c.start(.indefinite)
            var results: [Bool] = []
            c.beginHelperRemoval { _, ok in results.append(ok) }
            await until { results.count == 1 }
            #expect(results == [!markerPresent])
            #expect(backend.freshInfoCalls == 0)
        }
    }

    /// With the helper service: a re-registration that did not finish leaves no daemon
    /// registered while the status is `.error`. The marker decides, so Remove is not refused
    /// for a daemon that cannot answer.
    @Test func removalWithAnUnregisteredDaemonInErrorFollowsTheMarker() async {
        for markerPresent in [true, false] {
            let backend = FakeBackend()
            backend.stubStatus = .error("re-registering failed")
            backend.daemonMayRunOverride = false
            backend.freshInfoError = .rejected("not registered")
            let (c, _) = serviceController(backend, marker: MemoryOwnershipStore(exists: markerPresent))
            c.settings.lidModeEnabled = true
            c.start(.indefinite)
            var results: [Bool] = []
            c.beginHelperRemoval { _, ok in results.append(ok) }
            await until { results.count == 1 }
            #expect(results == [!markerPresent])
            #expect(backend.freshInfoCalls == 0)
            #expect(backend.setCalls.isEmpty)
        }
    }

    /// With the helper service: an earlier failed release, with lid mode already unwanted,
    /// is sent again ahead of the check.
    @Test func removalResendsAFailedReleaseToTheDaemon() async {
        let backend = FakeBackend()
        backend.stubInfo = HelperInfo(version: "0.4.0", build: "1", sleepDisabled: false, owned: false)
        let (c, service) = serviceController(backend)
        c.settings.lidModeEnabled = true
        c.start(.indefinite)
        await until { service.hold == LidHold(held: true, pending: false, failure: nil) }
        backend.failNextSet = .commandFailed("pmset failed")
        c.setLidMode(false)
        await until { service.hold.failure != nil }
        var results: [Bool] = []
        c.beginHelperRemoval { _, ok in results.append(ok) }
        await until { results == [true] }
        #expect(backend.setCalls == [true, false, false])
    }
}
