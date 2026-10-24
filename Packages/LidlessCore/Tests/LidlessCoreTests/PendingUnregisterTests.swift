import Foundation
import Testing
@testable import LidlessCore

@Suite struct PendingUnregisterTests {
    private struct Failure: Error {}

    @Test func waitTimesOutWhileOutstandingThenSeesALateCompletion() {
        let pending = PendingUnregister()
        #expect(pending.wait(timeout: 0) == nil)
        pending.complete(nil)
        if case .success? = pending.wait(timeout: 0) {} else { Issue.record("late completion lost") }
        // Waiting again after a result still returns it.
        if case .success? = pending.wait(timeout: 0) {} else { Issue.record("second wait lost the result") }
    }

    @Test func completionWakesAWaiter() {
        let pending = PendingUnregister()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { pending.complete(Failure()) }
        if case .failure? = pending.wait(timeout: 5) {} else { Issue.record("waiter not woken with the error") }
    }

    @Test func onlyTheFirstCompletionCounts() {
        let pending = PendingUnregister()
        pending.complete(nil)
        pending.complete(Failure())
        if case .success? = pending.wait(timeout: 0) {} else { Issue.record("second completion replaced the first") }
    }
}
