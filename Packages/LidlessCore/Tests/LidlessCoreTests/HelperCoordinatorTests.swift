import Testing
import Foundation
@testable import LidlessCore

@MainActor private final class HeldFlag {
    var value = true
}

@MainActor
struct HelperCoordinatorTests {
    let backend = FakeBackend()
    let scheduler = ManualPollScheduler()

    func make(status: HelperStatus, legacy: Bool = false, held: @escaping @MainActor () -> Bool = { false })
        -> HelperCoordinator {
        backend.stubStatus = status
        backend.legacyPresent = legacy
        return HelperCoordinator(backend: backend, scheduler: scheduler, lidModeHeld: held)
    }

    @Test func becomingInstalledFiresOnce() async {
        let c = make(status: .needsApproval)
        var fired = 0
        c.onBecameInstalled = { fired += 1 }
        await c.refresh().value
        #expect(fired == 0)
        backend.stubStatus = .installed
        await c.refresh().value
        await c.refresh().value
        #expect(fired == 1)
        #expect(c.status == .installed)
        #expect(backend.refreshInfoCalls == 3)
    }

    /// A daemon checked after launch (or after a re-registration) is a transition too.
    @Test func checkedDaemonBecomesInstalled() async {
        let c = make(status: .checking)
        var fired = 0
        c.onBecameInstalled = { fired += 1 }
        backend.statusAfterRefresh = .installed
        await c.refresh().value
        #expect(fired == 1)
        #expect(c.status == .installed)
    }

    /// The daemon's answer (shown on the Helper tab) may change with the status unchanged.
    @Test func onChangeAfterRefreshWithUnchangedStatus() async {
        let c = make(status: .installed)
        var changes = 0
        c.onChange = { changes += 1 }
        await c.refresh().value
        #expect(c.status == .installed)
        #expect(changes == 1)
    }

    /// Checking waits like the approval: a refresh that did not settle it (one that began
    /// before an install) is followed by another.
    @Test func pollsWhileChecking() async {
        let c = make(status: .checking)
        await c.refresh().value
        #expect(scheduler.active.count == 1)
        backend.stubStatus = .installed
        scheduler.fire()
        #expect(c.status == .installed)
        #expect(scheduler.active.isEmpty)
    }

    @Test func installedAtLaunchIsNoTransition() async {
        let c = make(status: .installed)
        var fired = 0
        c.onBecameInstalled = { fired += 1 }
        await c.refresh().value
        #expect(fired == 0)
    }

    @Test func pollsOnlyWhileWaitingForApproval() async {
        let c = make(status: .notInstalled)
        await c.refresh().value
        #expect(scheduler.handles.isEmpty)
        backend.stubStatus = .needsApproval
        await c.refresh().value
        await c.refresh().value
        #expect(scheduler.active.count == 1)
        #expect(scheduler.intervals == [1])
        #expect(c.isPolling)
        // A tick refreshes; the approval stops the polling.
        backend.stubStatus = .installed
        scheduler.fire()
        #expect(c.status == .installed)
        #expect(scheduler.active.isEmpty)
        #expect(!c.isPolling)
    }

    @Test func pollingStopsOnAnyOtherStatus() async {
        for other in [HelperStatus.notInstalled, .unsigned, .error("x")] {
            let scheduler = ManualPollScheduler()
            backend.stubStatus = .needsApproval
            let c = HelperCoordinator(backend: backend, scheduler: scheduler, lidModeHeld: { false })
            await c.refresh().value
            #expect(scheduler.active.count == 1)
            backend.stubStatus = other
            await c.refresh().value
            #expect(scheduler.active.isEmpty)
        }
    }

    @Test func refreshesDoNotPileUp() async {
        let c = make(status: .needsApproval)
        let first = c.refresh()
        let second = c.refresh()
        await first.value
        await second.value
        #expect(backend.refreshInfoCalls == 1)
    }

    @Test func fallbackRemovesLegacyHelperOnce() async {
        let c = make(status: .installed, legacy: true)
        await c.refresh().value
        #expect(backend.removeLegacyCalls == 1)
        #expect(c.legacyRemoved)
        #expect(c.legacyError == nil)
        await c.refresh().value
        #expect(backend.removeLegacyCalls == 1)
    }

    @Test func fallbackWaitsForInstalledAndLidModeReleased() async {
        let held = HeldFlag()
        let c = make(status: .needsApproval, legacy: true, held: { held.value })
        await c.refresh().value
        #expect(backend.removeLegacyCalls == 0)
        backend.stubStatus = .installed
        await c.refresh().value
        #expect(backend.removeLegacyCalls == 0)
        held.value = false
        await c.refresh().value
        #expect(backend.removeLegacyCalls == 1)
        #expect(c.legacyRemoved)
    }

    @Test func busyIsRetriedLater() async {
        let c = make(status: .installed, legacy: true)
        backend.removeLegacyError = .commandFailed("busy: closed-lid mode is active")
        await c.refresh().value
        #expect(backend.removeLegacyCalls == 1)
        #expect(c.legacyError == nil)
        backend.removeLegacyError = nil
        await c.refresh().value
        #expect(backend.removeLegacyCalls == 2)
        #expect(c.legacyRemoved)
    }

    @Test func failureIsKeptAndNotRetried() async {
        let c = make(status: .installed, legacy: true)
        var changes = 0
        c.onChange = { changes += 1 }
        backend.removeLegacyError = .commandFailed("cannot unlink /etc/sudoers.d/lidless")
        await c.refresh().value
        #expect(c.legacyError == "cannot unlink /etc/sudoers.d/lidless")
        #expect(!c.legacyRemoved)
        #expect(changes >= 1)
        backend.removeLegacyError = nil
        await c.refresh().value
        #expect(backend.removeLegacyCalls == 1)
        #expect(c.legacyError == "cannot unlink /etc/sudoers.d/lidless")
    }

    /// On approval the fallback goes before the callback, which may take lid mode and would
    /// otherwise make the daemon refuse it; its error is kept.
    @Test func fallbackRunsBeforeOnBecameInstalled() async {
        let held = HeldFlag()
        held.value = false
        let c = make(status: .needsApproval, legacy: true, held: { held.value })
        backend.removeLegacyError = .commandFailed("cannot unlink /etc/sudoers.d/lidless")
        var callsSeenByCallback: [Int] = []
        c.onBecameInstalled = { [backend] in
            callsSeenByCallback.append(backend.removeLegacyCalls)
            held.value = true
        }
        await c.refresh().value
        backend.stubStatus = .installed
        await c.refresh().value
        #expect(callsSeenByCallback == [1])
        #expect(backend.removeLegacyCalls == 1)
        #expect(c.legacyError == "cannot unlink /etc/sudoers.d/lidless")
    }

    /// The daemon removed the files itself at start: the line shows without an app call.
    @Test func removalByTheDaemonIsDetected() async {
        let c = make(status: .needsApproval, legacy: true)
        #expect(!c.legacyRemoved)
        backend.legacyPresent = false
        backend.stubStatus = .installed
        await c.refresh().value
        #expect(c.legacyRemoved)
        #expect(backend.removeLegacyCalls == 0)
    }

    @Test func noLegacyHelperNoLine() async {
        let c = make(status: .installed)
        await c.refresh().value
        #expect(!c.legacyRemoved)
        #expect(backend.removeLegacyCalls == 0)
    }
}
