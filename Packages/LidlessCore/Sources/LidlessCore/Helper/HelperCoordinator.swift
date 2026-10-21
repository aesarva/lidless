import Foundation
import os

/// A repeating poll on the main actor (a run-loop timer in the app, driven by hand in tests).
@MainActor public protocol PollScheduler: AnyObject {
    func startPolling(every interval: TimeInterval, _ tick: @escaping @MainActor () -> Void) -> PollHandle
}

@MainActor public protocol PollHandle: AnyObject {
    func cancel()
}

/// `PollScheduler` on the main run loop in common modes, so it also fires while a menu is open.
@MainActor public final class RunLoopPollScheduler: PollScheduler {
    public init() {}

    public func startPolling(every interval: TimeInterval, _ tick: @escaping @MainActor () -> Void) -> PollHandle {
        let timer = Timer(timeInterval: interval, repeats: true) { _ in
            MainActor.assumeIsolated { tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        return TimerHandle(timer: timer)
    }

    private final class TimerHandle: PollHandle {
        let timer: Timer
        init(timer: Timer) { self.timer = timer }
        func cancel() { timer.invalidate() }
    }
}

/// The app side of the helper's life: notices the status turning `.installed`, polls while
/// macOS waits for the user's approval, and notices the 0.2.0 helper going away. The daemon
/// removes the 0.2.0 helper itself when it starts; this only falls back to asking it once
/// per launch if the files are still there.
@MainActor public final class HelperCoordinator {
    public private(set) var status: HelperStatus
    /// The 0.2.0 helper was present earlier in this launch and is gone now (whoever removed it).
    public private(set) var legacyRemoved = false
    /// Why the fallback removal failed; the daemon tries again when it next starts.
    public private(set) var legacyError: String?
    /// The status turned `.installed` (once per transition).
    public var onBecameInstalled: (() -> Void)?
    /// Any of `status`, `legacyRemoved`, `legacyError` changed.
    public var onChange: (() -> Void)?
    public var isPolling: Bool { poll != nil }

    private let backend: PrivilegedBackend
    private let scheduler: PollScheduler
    private let lidModeHeld: @MainActor () -> Bool
    private let pollInterval: TimeInterval
    private let log = Logger(subsystem: HelperIDs.app, category: "helper")
    private var poll: PollHandle?
    private var refreshTask: Task<Void, Never>?
    private var legacySeen = false
    /// The 0.2.0 files are gone (or never were): no more checks this launch.
    private var legacyGone = false
    private var fallbackAttempted = false

    /// `lidModeHeld`: whether this app holds closed-lid mode now; the daemon refuses the
    /// removal then.
    public init(backend: PrivilegedBackend, scheduler: PollScheduler,
                lidModeHeld: @escaping @MainActor () -> Bool, pollInterval: TimeInterval = 1) {
        self.backend = backend
        self.scheduler = scheduler
        self.lidModeHeld = lidModeHeld
        self.pollInterval = pollInterval
        status = backend.status()
        _ = checkLegacy()
    }

    /// Updates the status now, then asks the daemon in the background and updates again
    /// (and tries the fallback removal). While one is running, returns that one instead.
    @discardableResult
    public func refresh() -> Task<Void, Never> {
        update()
        if let refreshTask { return refreshTask }
        let backend = self.backend
        let task = Task {
            await Task.detached { backend.refreshInfo() }.value
            update()
            await removeLegacyIfNeeded()
            refreshTask = nil
        }
        refreshTask = task
        return task
    }

    private func update() {
        let current = backend.status()
        let becameInstalled = current == .installed && status != .installed
        var changed = checkLegacy()
        if current != status {
            status = current
            changed = true
        }
        updatePolling()
        if changed { onChange?() }
        if becameInstalled { onBecameInstalled?() }
    }

    /// Polls while macOS waits for the user's approval: a menu-bar app is not told when they
    /// allow it, and lid mode should turn on right then.
    private func updatePolling() {
        guard status == .needsApproval else {
            poll?.cancel()
            poll = nil
            return
        }
        guard poll == nil else { return }
        poll = scheduler.startPolling(every: pollInterval) { [weak self] in self?.refresh() }
    }

    /// Returns true when `legacyRemoved` changed.
    private func checkLegacy() -> Bool {
        guard !legacyGone else { return false }
        if backend.legacyHelperPresent() {
            legacySeen = true
            return false
        }
        legacyGone = true
        guard legacySeen else { return false }
        legacyRemoved = true
        return true
    }

    /// Asks the daemon to remove 0.2.0 files it did not remove at start. "Busy" (lid mode
    /// held) does not count as the attempt; any other failure is kept and not retried.
    private func removeLegacyIfNeeded() async {
        guard status == .installed, !legacyGone, !fallbackAttempted, !lidModeHeld() else { return }
        let backend = self.backend
        let failure: String? = await Task.detached {
            do {
                _ = try backend.removeLegacyHelper()
                return nil
            } catch {
                return HelperError.message(for: error)
            }
        }.value
        if let failure, failure.hasPrefix("busy") {
            log.notice("0.2.0 helper not removed yet: \(failure, privacy: .public)")
            return
        }
        fallbackAttempted = true
        var changed = checkLegacy()
        if let failure {
            log.error("removing the 0.2.0 helper failed: \(failure, privacy: .public)")
            legacyError = failure
            changed = true
        }
        if changed { onChange?() }
    }
}
