import Foundation
import os

public protocol HelperCancellable: Sendable {
    func cancel()
}

/// Runs one-shot work later. The work must not run on a queue that `HelperLifecycle` waits on.
public protocol HelperScheduler: Sendable {
    func schedule(after delay: TimeInterval, _ work: @escaping @Sendable () -> Void) -> HelperCancellable
}

/// `HelperScheduler` on a private serial queue.
public final class DispatchHelperScheduler: HelperScheduler {
    private let queue = DispatchQueue(label: "io.github.aesarva.Lidless.helper.timers")

    public init() {}

    public func schedule(after delay: TimeInterval, _ work: @escaping @Sendable () -> Void) -> HelperCancellable {
        let item = DispatchWorkItem(block: work)
        queue.asyncAfter(deadline: .now() + delay, execute: item)
        return WorkItem(item: item)
    }

    private struct WorkItem: HelperCancellable, @unchecked Sendable {
        let item: DispatchWorkItem
        func cancel() { item.cancel() }
    }
}

/// When the daemon may exit, and when to retry a failed `disablesleep` reset.
///
/// The connection count, timers and the exit decision live on one serial queue, which never
/// waits for pmset: SleepGuard is read and retried on the caller's thread (an XPC or timer
/// queue), and only `shutdownIfIdle`, which does not run pmset, is called on the queue.
/// So the listener delegate can call `connectionWillActivate()` synchronously.
public final class HelperLifecycle: @unchecked Sendable {
    public static let idleDelay: TimeInterval = 10
    public static let retryInterval: TimeInterval = 15
    private static let log = Logger(subsystem: HelperIDs.helper, category: "daemon")

    private let sleepGuard: SleepGuard
    private let scheduler: HelperScheduler
    private let exit: @Sendable () -> Void
    private let queue = DispatchQueue(label: "io.github.aesarva.Lidless.helper.lifecycle")

    // On `queue` only.
    private var connections = 0
    private var exiting = false
    /// Identifies the current timer, so a cancelled one that fires anyway does nothing.
    private var idleTimer: (id: Int, task: HelperCancellable)?
    private var retryTimer: (id: Int, task: HelperCancellable)?
    private var nextTimerID = 0
    /// Orders `reevaluate` calls: an older reading of SleepGuard never overrides a newer one.
    private var nextReading = 0
    private var appliedReading = 0

    public init(guard sleepGuard: SleepGuard, scheduler: HelperScheduler, exit: @escaping @Sendable () -> Void) {
        self.sleepGuard = sleepGuard
        self.scheduler = scheduler
        self.exit = exit
    }

    /// Call before resuming an accepted connection; false means the daemon is exiting and the
    /// connection must be rejected.
    public func connectionWillActivate() -> Bool {
        queue.sync {
            guard !exiting else { return false }
            connections += 1
            cancelIdleTimer()
            return true
        }
    }

    /// Call from the connection's invalidation handler: releases its holder (may block in pmset).
    public func connectionDidClose(holder: UUID) {
        do {
            try sleepGuard.release(holder)
        } catch {
            Self.log.error("release \(holder, privacy: .public) on disconnect failed: \(HelperError.message(for: error), privacy: .public)")
        }
        queue.sync { connections -= 1 }
        reevaluate()
    }

    /// Re-checks both timers; call after anything that may change SleepGuard's state.
    public func reevaluate() {
        let reading = queue.sync { () -> Int in
            nextReading += 1
            return nextReading
        }
        // Read outside the queue: these wait for any pmset call in progress.
        let pending = sleepGuard.hasPendingReset
        let idle = sleepGuard.isIdle
        queue.sync {
            guard reading > appliedReading, !exiting else { return }
            appliedReading = reading
            if pending {
                if retryTimer == nil { startRetryTimer() }
            } else {
                cancelRetryTimer()
            }
            if connections == 0, idle {
                if idleTimer == nil { startIdleTimer() }
            } else {
                cancelIdleTimer()
            }
        }
    }

    // MARK: - Timers (on `queue`)

    private func makeTimerID() -> Int {
        nextTimerID += 1
        return nextTimerID
    }

    private func cancelIdleTimer() {
        idleTimer?.task.cancel()
        idleTimer = nil
    }

    private func cancelRetryTimer() {
        retryTimer?.task.cancel()
        retryTimer = nil
    }

    private func startIdleTimer() {
        let id = makeTimerID()
        let task = scheduler.schedule(after: Self.idleDelay) { [weak self] in self?.idleTimerFired(id) }
        idleTimer = (id, task)
    }

    private func startRetryTimer() {
        let id = makeTimerID()
        let task = scheduler.schedule(after: Self.retryInterval) { [weak self] in self?.retryTimerFired(id) }
        retryTimer = (id, task)
    }

    private func idleTimerFired(_ id: Int) {
        let shouldExit = queue.sync { () -> Bool in
            guard idleTimer?.id == id, !exiting else { return false }
            idleTimer = nil
            // Closing the guard makes the decision final: a late acquire now throws.
            guard connections == 0, sleepGuard.shutdownIfIdle() else { return false }
            exiting = true
            cancelRetryTimer()
            return true
        }
        if shouldExit {
            Self.log.notice("idle, exiting")
            exit()
        } else {
            reevaluate()
        }
    }

    private func retryTimerFired(_ id: Int) {
        let current = queue.sync { () -> Bool in
            guard retryTimer?.id == id, !exiting else { return false }
            retryTimer = nil
            return true
        }
        guard current else { return }
        do {
            try sleepGuard.retryPendingReset()
            if sleepGuard.isIdle { Self.log.notice("pending disablesleep reset done") }
        } catch {
            Self.log.error("pending disablesleep reset failed: \(HelperError.message(for: error), privacy: .public)")
        }
        reevaluate()
    }
}
