import Foundation
import Testing
@testable import LidlessCore

/// Virtual clock: work runs synchronously, on the calling thread, from `advance(by:)`.
private final class ManualScheduler: HelperScheduler, @unchecked Sendable {
    private final class Task: HelperCancellable, @unchecked Sendable {
        let due: TimeInterval
        let work: @Sendable () -> Void
        private let lock = NSLock()
        private var _cancelled = false
        var cancelled: Bool { lock.withLock { _cancelled } }
        init(due: TimeInterval, work: @escaping @Sendable () -> Void) { self.due = due; self.work = work }
        func cancel() { lock.withLock { _cancelled = true } }
    }

    private let lock = NSLock()
    private var now: TimeInterval = 0
    private var tasks: [Task] = []

    func schedule(after delay: TimeInterval, _ work: @escaping @Sendable () -> Void) -> HelperCancellable {
        lock.withLock {
            let task = Task(due: now + delay, work: work)
            tasks.append(task)
            return task
        }
    }

    /// Delays (from now) of the live, not yet run tasks.
    var pendingDelays: [TimeInterval] {
        lock.withLock { tasks.filter { !$0.cancelled }.map { $0.due - now }.sorted() }
    }

    func advance(by seconds: TimeInterval) {
        let end = lock.withLock { now + seconds }
        while true {
            let next: Task? = lock.withLock {
                tasks.removeAll { $0.cancelled }
                guard let task = tasks.filter({ $0.due <= end }).min(by: { $0.due < $1.due }) else { return nil }
                tasks.removeAll { $0 === task }
                now = task.due
                return task
            }
            guard let next else { break }
            next.work()
        }
        lock.withLock { now = end }
    }
}

private final class ExitRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    var count: Int { lock.withLock { n } }
    func record() { lock.withLock { n += 1 } }
}

@Suite struct HelperLifecycleTests {
    private let a = UUID()

    private func make(initial: Bool = false, file: Bool = false)
        -> (HelperLifecycle, SleepGuard, FakeSleepSetting, ManualScheduler, ExitRecorder) {
        let store = MemoryOwnershipStore(exists: file)
        let setting = FakeSleepSetting(initial: initial, store: store)
        let guardian = SleepGuard(setting: setting, store: store)
        let scheduler = ManualScheduler()
        let exits = ExitRecorder()
        let lifecycle = HelperLifecycle(guard: guardian, scheduler: scheduler) { exits.record() }
        return (lifecycle, guardian, setting, scheduler, exits)
    }

    @Test func idleExitAfterTenSecondsWithoutConnections() {
        let (lifecycle, _, _, scheduler, exits) = make()
        lifecycle.reevaluate()
        scheduler.advance(by: 9.9)
        #expect(exits.count == 0)
        scheduler.advance(by: 0.1)
        #expect(exits.count == 1)
    }

    @Test func connectionBeforeTimerPreventsExit() {
        let (lifecycle, _, _, scheduler, exits) = make()
        lifecycle.reevaluate()
        scheduler.advance(by: 5)
        #expect(lifecycle.connectionWillActivate())
        scheduler.advance(by: 30)
        #expect(exits.count == 0)
        // Closing it starts a fresh 10 s countdown.
        lifecycle.connectionDidClose(holder: a)
        scheduler.advance(by: 9)
        #expect(exits.count == 0)
        scheduler.advance(by: 1)
        #expect(exits.count == 1)
    }

    @Test func connectionRefusedAfterExitDecided() {
        let (lifecycle, _, _, scheduler, exits) = make()
        lifecycle.reevaluate()
        scheduler.advance(by: 10)
        #expect(exits.count == 1)
        #expect(!lifecycle.connectionWillActivate())
    }

    @Test func noExitWhileHeld() throws {
        let (lifecycle, guardian, _, scheduler, exits) = make()
        #expect(lifecycle.connectionWillActivate())
        try guardian.acquire(a)
        // Another connection's close leaves this holder in place.
        lifecycle.connectionDidClose(holder: UUID())
        scheduler.advance(by: 60)
        #expect(exits.count == 0)
        #expect(scheduler.pendingDelays.isEmpty)
    }

    @Test func pendingResetIsRetriedThenExitFollows() throws {
        let (lifecycle, guardian, setting, scheduler, exits) = make()
        #expect(lifecycle.connectionWillActivate())
        try guardian.acquire(a)
        setting.failWriteZeroTimes = 2
        lifecycle.connectionDidClose(holder: a)
        #expect(guardian.hasPendingReset)
        // Only the retry timer: no idle exit while a reset is pending.
        #expect(scheduler.pendingDelays == [15])
        scheduler.advance(by: 15) // second failure
        #expect(setting.writes == [true])
        #expect(scheduler.pendingDelays == [15])
        scheduler.advance(by: 15) // succeeds
        #expect(setting.writes == [true, false])
        #expect(exits.count == 0)
        #expect(scheduler.pendingDelays == [10])
        scheduler.advance(by: 10)
        #expect(exits.count == 1)
    }

    @Test func retryTimerOnlyWhilePending() throws {
        let (lifecycle, guardian, setting, scheduler, _) = make()
        #expect(lifecycle.connectionWillActivate())
        lifecycle.reevaluate()
        #expect(scheduler.pendingDelays.isEmpty)
        try guardian.acquire(a)
        lifecycle.reevaluate()
        #expect(scheduler.pendingDelays.isEmpty)
        setting.failWriteZeroTimes = 1
        #expect(throws: FakeSleepSettingError.self) { try guardian.release(a) }
        lifecycle.reevaluate()
        #expect(scheduler.pendingDelays == [15])
        // Taken over by a new holder: the retry stops.
        try guardian.acquire(a)
        lifecycle.reevaluate()
        #expect(scheduler.pendingDelays.isEmpty)
    }

    @Test func failedRecoveryAtStartBlocksExitUntilRetried() throws {
        let (lifecycle, guardian, setting, scheduler, exits) = make(initial: true, file: true)
        setting.failWriteZeroTimes = 1
        #expect(throws: FakeSleepSettingError.self) { try guardian.recoverAtStart() }
        lifecycle.reevaluate()
        scheduler.advance(by: 14)
        #expect(exits.count == 0)
        scheduler.advance(by: 1)
        #expect(setting.writes == [false])
        scheduler.advance(by: 10)
        #expect(exits.count == 1)
    }

    @Test func idleExitClosesTheGuard() {
        let (lifecycle, guardian, setting, scheduler, exits) = make()
        lifecycle.reevaluate()
        scheduler.advance(by: 10)
        #expect(exits.count == 1)
        #expect(throws: HelperError.commandFailed("shutting down")) { try guardian.acquire(a) }
        #expect(setting.fileExistedAtAttempt.isEmpty)
    }
}
