import Testing
import Foundation
@testable import LidlessCore

@MainActor
struct LidSleepServiceTests {
    let backend = FakeBackend()

    /// Every hold the service published, in order.
    @MainActor final class Holds {
        var all: [LidHold] = []
    }

    func service(first: (@Sendable () -> Void)? = nil) -> (LidSleepService, Holds) {
        let svc = LidSleepService(backend: backend, first: first)
        let holds = Holds()
        svc.onChange = { holds.all.append($0) }
        return (svc, holds)
    }

    /// The queue runs off the main actor: wait for it, up to 2 s.
    func until(_ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(2)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        #expect(condition())
    }

    /// Waits for `semaphore` off the main actor.
    func waitOff(_ semaphore: DispatchSemaphore) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                semaphore.wait()
                done.resume()
            }
        }
    }

    /// Returns once everything queued so far has run and reported (a confirmation is queued
    /// behind it and answered on the main actor after the steps' results).
    func flush(_ svc: LidSleepService) async {
        var done = false
        svc.confirmReleased { _ in done = true }
        await until { done }
    }

    func info(owned: Bool) -> HelperInfo {
        HelperInfo(version: "0.4.0", build: "1", sleepDisabled: owned, owned: owned)
    }

    // MARK: - Converging to the wish

    @Test func lastWishWins() async {
        let (svc, _) = service()
        backend.holdSets = true
        svc.setWanted(true)
        await until { backend.setCalls == [true] }
        svc.setWanted(false)
        svc.setWanted(true)
        backend.holdSets = false
        backend.releaseSet()
        await until { svc.hold.held }
        await flush(svc)
        #expect(svc.hold == LidHold(held: true, pending: false, failure: nil))
        #expect(backend.setCalls.count <= 3)
        #expect(backend.setCalls.last == true)
    }

    /// The daemon may still hold for an earlier request this process no longer knows about.
    @Test func wantedFalseAlwaysCallsDaemon() async {
        let (svc, _) = service()
        #expect(!svc.hold.held)
        svc.setWanted(false)
        await until { backend.setCalls == [false] }
        await flush(svc)
        #expect(svc.hold == LidHold())
    }

    @Test func setWantedPublishesPendingAtOnce() async {
        let (svc, holds) = service()
        backend.holdSets = true
        svc.setWanted(true)
        #expect(holds.all == [LidHold(held: false, pending: true, failure: nil)])
        backend.holdSets = false
        backend.releaseSet()
        await until { svc.hold.held }
        #expect(holds.all.last == LidHold(held: true, pending: false, failure: nil))
    }

    @Test func enableThenDisable() async {
        let (svc, _) = service()
        svc.setWanted(true)
        await until { svc.hold.held }
        svc.setWanted(false)
        await until { !svc.hold.held }
        await flush(svc)
        #expect(backend.setCalls == [true, false])
        #expect(svc.hold == LidHold())
    }

    @Test func failedEnableReportsAndRetries() async {
        let (svc, _) = service()
        backend.failNextSet = .commandFailed("x")
        svc.setWanted(true)
        await until { svc.hold.failure != nil }
        #expect(svc.hold == LidHold(held: false, pending: false, failure: "x"))
        svc.retry()
        await until { svc.hold.held }
        #expect(svc.hold.failure == nil)
        #expect(backend.setCalls == [true, true])
    }

    /// A failed release keeps the hold (disablesleep may still be 1) until a retry gets through.
    @Test func failedReleaseKeepsHoldUntilRetry() async {
        let (svc, _) = service()
        svc.setWanted(true)
        await until { svc.hold.held }
        backend.failNextSet = .commandFailed("y")
        svc.setWanted(false)
        await until { svc.hold.failure != nil }
        #expect(svc.hold == LidHold(held: true, pending: false, failure: "y"))
        svc.retry()
        await until { !svc.hold.held }
        #expect(svc.hold == LidHold())
        #expect(backend.setCalls == [true, false, false])
    }

    /// Nothing to retry once the wish is reached.
    @Test func retryWithoutFailureDoesNothing() async {
        let (svc, _) = service()
        svc.setWanted(true)
        await until { svc.hold.held }
        svc.retry()
        await flush(svc)
        #expect(backend.setCalls == [true])
    }

    @Test func enableWaitsBehindLegacyReset() async {
        let started = DispatchSemaphore(value: 0)
        let gate = DispatchSemaphore(value: 0)
        let (svc, _) = service(first: {
            started.signal()
            gate.wait()
        })
        // The reset runs on the queue now; the serial queue keeps the step behind it.
        await waitOff(started)
        svc.setWanted(true)
        #expect(svc.hold.pending)
        #expect(backend.setCalls.isEmpty)
        gate.signal()
        await until { svc.hold.held }
        #expect(backend.setCalls == [true])
    }

    /// An acquisition from an earlier wish lands after a newer wish was refused unsent: the
    /// wish is reached, so the refusal is no failure any more.
    @Test func reachedWishClearsAStaleFailure() async {
        let (svc, _) = service()
        backend.holdSets = true
        svc.setWanted(true)
        await until { backend.setCalls == [true] }
        backend.stubStatus = .checking
        svc.setWanted(true)
        #expect(svc.hold.failure == LidHold.helperNotReady)
        backend.holdSets = false
        backend.releaseSet()
        await until { svc.hold.held }
        await flush(svc)
        #expect(svc.hold == LidHold(held: true, pending: false, failure: nil))
    }

    /// Nothing held here is no proof the daemon holds nothing: a failed release still counts.
    @Test func failedReleaseWithNothingHeldKeepsItsFailure() async {
        let (svc, _) = service()
        backend.failNextSet = .commandFailed("y")
        svc.setWanted(false)
        await until { svc.hold.failure != nil }
        await flush(svc)
        #expect(svc.hold == LidHold(held: false, pending: false, failure: "y"))
    }

    // MARK: - Helper status

    /// Only a daemon verified for this registration is asked to take the hold.
    @Test func enableRefusedUnlessVerified() async {
        for status in [HelperStatus.error("x"), .checking, .notInstalled, .needsApproval, .unsigned] {
            let backend = FakeBackend()
            backend.stubStatus = status
            let svc = LidSleepService(backend: backend)
            svc.setWanted(true)
            await until { svc.hold.failure != nil }
            #expect(svc.hold == LidHold(held: false, pending: false, failure: LidHold.helperNotReady))
            #expect(backend.setCalls.isEmpty)
        }
    }

    @Test func releaseAllowedUnderError() async {
        for status in [HelperStatus.error("x"), .checking] {
            let backend = FakeBackend()
            backend.stubStatus = status
            let svc = LidSleepService(backend: backend)
            svc.setWanted(false)
            await until { backend.setCalls == [false] }
        }
    }

    /// No daemon is registered: nothing can hold disablesleep for this app.
    @Test func releaseWithoutRegisteredDaemonNeedsNoCall() async {
        for status in [HelperStatus.notInstalled, .needsApproval, .unsigned] {
            let backend = FakeBackend()
            backend.stubStatus = status
            let svc = LidSleepService(backend: backend)
            svc.setWanted(false)
            var confirmed: Bool?
            svc.confirmReleased { confirmed = $0 }
            await until { confirmed != nil }
            #expect(confirmed == true)
            #expect(svc.hold == LidHold())
            #expect(backend.setCalls.isEmpty)
        }
    }

    /// For a removal, no registered daemon is no proof: only an ownership marker known to be
    /// absent is (it is left while the daemon may still hold disablesleep).
    @Test func removalConfirmWithoutRunningDaemonReadsTheMarker() async {
        for status in [HelperStatus.notInstalled, .needsApproval, .unsigned] {
            for markerPresent in [true, false] {
                let backend = FakeBackend()
                backend.stubStatus = status
                let marker = MemoryOwnershipStore(exists: markerPresent)
                let svc = LidSleepService(backend: backend, markerAbsent: { !marker.exists() })
                var confirmed: Bool?
                svc.confirmReleasedForRemoval { confirmed = $0 }
                await until { confirmed != nil }
                #expect(confirmed == !markerPresent)
                #expect(backend.freshInfoCalls == 0)
            }
        }
    }

    /// A running daemon must answer afresh that it owns nothing; no answer is a refusal.
    @Test func removalConfirmWithRunningDaemonNeedsFreshInfo() async {
        for status in [HelperStatus.installed, .checking, .error("x")] {
            for (owned, fails, expected) in [(false, false, true), (true, false, false), (false, true, false)] {
                let backend = FakeBackend()
                backend.stubStatus = status
                backend.stubInfo = HelperInfo(version: "0.4.0", build: "1", sleepDisabled: owned, owned: owned)
                if fails { backend.freshInfoError = .timedOut }
                let svc = LidSleepService(backend: backend, markerAbsent: { true })
                var confirmed: Bool?
                svc.confirmReleasedForRemoval { confirmed = $0 }
                await until { confirmed != nil }
                #expect(confirmed == expected)
                #expect(backend.freshInfoCalls == 1)
            }
        }
    }

    /// An acquisition refused while the daemon was being checked goes through once it is
    /// verified, even when the refusal comes back after the status changed.
    @Test func refusedEnableRetriesWhenVerifiedMeanwhile() async {
        // setWanted sees .installed and queues a step; the step sees .checking and refuses;
        // the refusal's answer finds the helper verified.
        backend.statusScript = [.installed, .checking]
        let (svc, holds) = service()
        svc.setWanted(true)
        await until { svc.hold.held }
        #expect(backend.statusScript.isEmpty)
        #expect(backend.setCalls == [true])
        #expect(!holds.all.contains { $0.failure != nil })
    }

    /// The status was `.installed` when the step looked, but a re-registration began before
    /// the acquisition: the backend refuses it unsent, and the service reports it as not ready.
    @Test func acquisitionRefusedByTheBackendIsNotReady() async {
        backend.statusScript = [.installed, .installed]
        backend.stubStatus = .checking
        let (svc, _) = service()
        svc.setWanted(true)
        await until { svc.hold.failure != nil }
        #expect(svc.hold == LidHold(held: false, pending: false, failure: LidHold.helperNotReady))
        #expect(backend.setCalls.isEmpty)
    }

    /// While the helper cannot take the hold, the poll's retries neither show lid mode on its
    /// way nor queue anything; once it is verified, a retry takes the hold.
    @Test func retryWaitsQuietlyForAVerifiedHelper() async {
        for status in [HelperStatus.checking, .needsApproval, .notInstalled, .unsigned, .error("x")] {
            let backend = FakeBackend()
            backend.stubStatus = status
            let svc = LidSleepService(backend: backend)
            let holds = Holds()
            svc.onChange = { holds.all.append($0) }
            svc.setWanted(true)
            for _ in 0..<3 { svc.retry() }
            await flush(svc)
            #expect(holds.all == [LidHold(held: false, pending: false, failure: LidHold.helperNotReady)])
            backend.stubStatus = .installed
            svc.retry()
            await until { svc.hold.held }
            #expect(backend.setCalls == [true])
        }
    }

    // MARK: - Lost connections

    @Test func lossBeforeEnableReplyMeansNotHeld() async {
        let (svc, _) = service()
        backend.holdSets = true
        svc.setWanted(true)
        await until { backend.setCalls == [true] }
        svc.connectionLost(generation: 1)
        backend.generation = 2
        backend.releaseSet()
        // The reply came over the lost connection: a new step takes the hold again.
        await until { backend.setCalls == [true, true] }
        #expect(!svc.hold.held)
        #expect(svc.hold.pending)
        backend.holdSets = false
        backend.releaseSet()
        await until { svc.hold.held }
    }

    @Test func lossEndsTheHoldAndReacquires() async {
        let (svc, holds) = service()
        svc.setWanted(true)
        await until { svc.hold.held }
        backend.generation = 2
        svc.connectionLost(generation: 1)
        #expect(holds.all.contains(LidHold(held: false, pending: true, failure: nil)))
        await until { svc.hold.held }
        #expect(backend.setCalls == [true, true])
    }

    /// The re-acquisition after a loss waits for a verified daemon, like any other.
    @Test func lossThenFailedVerificationDoesNotReacquire() async {
        let (svc, _) = service()
        svc.setWanted(true)
        await until { svc.hold.held }
        backend.stubStatus = .error("x")
        svc.connectionLost(generation: 1)
        #expect(!svc.hold.held)
        await until { svc.hold.failure != nil }
        await flush(svc)
        #expect(backend.setCalls == [true])
        #expect(svc.hold == LidHold(held: false, pending: false, failure: LidHold.helperNotReady))
    }

    /// A late report about an older connection says nothing about a hold on a newer one.
    @Test func staleLossKeepsANewerHold() async {
        let (svc, _) = service()
        svc.setWanted(true)
        await until { svc.hold.held }
        svc.setWanted(false)
        await until { !svc.hold.held }
        backend.generation = 2
        svc.setWanted(true)
        await until { svc.hold.held }
        svc.connectionLost(generation: 1)
        #expect(svc.hold.held)
        await flush(svc)
        #expect(backend.setCalls == [true, false, true])
    }

    /// A newer connection dropping means the holding one was already gone.
    @Test func newerLossEndsAnOlderHold() async {
        let (svc, _) = service()
        svc.setWanted(true)
        await until { svc.hold.held }
        backend.generation = 3
        svc.connectionLost(generation: 2)
        #expect(!svc.hold.held)
        await until { svc.hold.held }
        #expect(backend.setCalls == [true, true])
    }

    /// The daemon let go when the connection dropped: a release that failed is moot.
    @Test func lossAfterFailedReleaseReachesTheWish() async {
        let (svc, _) = service()
        svc.setWanted(true)
        await until { svc.hold.held }
        backend.failNextSet = .commandFailed("y")
        svc.setWanted(false)
        await until { svc.hold.failure != nil }
        svc.connectionLost(generation: 1)
        #expect(svc.hold == LidHold())
        await flush(svc)
        #expect(backend.setCalls == [true, false])
    }

    @Test func lossWithNothingHeldIsIgnored() async {
        let (svc, holds) = service()
        svc.connectionLost(generation: 1)
        await flush(svc)
        #expect(holds.all.isEmpty)
        #expect(backend.setCalls.isEmpty)
    }

    // MARK: - Confirming a release

    @Test func confirmUsesFreshInfoAfterCommands() async {
        let (svc, _) = service()
        backend.stubInfo = info(owned: false)
        backend.freshInfoError = .timedOut
        backend.holdSets = true
        svc.setWanted(false)
        await until { backend.setCalls == [false] }
        var confirmed: Bool?
        svc.confirmReleased { confirmed = $0 }
        // Queued behind the release, which is still waiting on the serial queue.
        #expect(backend.freshInfoCalls == 0)
        #expect(confirmed == nil)
        backend.holdSets = false
        backend.releaseSet()
        await until { confirmed != nil }
        #expect(confirmed == false)
    }

    @Test func confirmTrueOnlyWhenTheDaemonOwnsNothing() async {
        let (svc, _) = service()
        var answers: [Bool] = []
        backend.stubInfo = info(owned: true)
        svc.confirmReleased { answers.append($0) }
        await until { answers.count == 1 }
        backend.stubInfo = info(owned: false)
        svc.confirmReleased { answers.append($0) }
        await until { answers.count == 2 }
        #expect(answers == [false, true])
    }

    /// A daemon that says it holds nothing has reached the wish "no" after a failed release.
    @Test func confirmedReleaseClearsTheFailure() async {
        let (svc, _) = service()
        svc.setWanted(true)
        await until { svc.hold.held }
        backend.failNextSet = .commandFailed("y")
        svc.setWanted(false)
        await until { svc.hold.failure != nil }
        backend.stubInfo = info(owned: false)
        var confirmed: Bool?
        svc.confirmReleased { confirmed = $0 }
        await until { confirmed != nil }
        #expect(confirmed == true)
        #expect(svc.hold == LidHold())
        svc.retry()
        await flush(svc)
        #expect(backend.setCalls == [true, false])
    }

    /// An answer that comes back after a new wish is about the old one: dropped.
    @Test func staleConfirmIsDropped() async {
        let (svc, _) = service()
        backend.stubInfo = info(owned: false)
        backend.holdSets = true
        svc.setWanted(false)
        await until { backend.setCalls == [false] }
        var stale: Bool?
        svc.confirmReleased { stale = $0 }
        svc.setWanted(true)
        backend.holdSets = false
        backend.releaseSet()
        await until { svc.hold.held }
        await flush(svc)
        #expect(stale == nil)
    }
}
