import Foundation
import os

/// Persisted "we set disablesleep to 1" flag, so a crashed daemon or a reboot can still undo it.
public protocol OwnershipStore: Sendable {
    func exists() -> Bool
    func create() throws
    /// Removing a missing file is not an error.
    func remove() throws
}

public struct FileOwnershipStore: OwnershipStore {
    public static let defaultURL = URL(fileURLWithPath: "/Library/Application Support/Lidless/sleep-owned")

    private let url: URL

    public init(url: URL = FileOwnershipStore.defaultURL) { self.url = url }

    public func exists() -> Bool { FileManager.default.fileExists(atPath: url.path) }

    /// True only when the file is known not to exist: a check that fails for another reason
    /// (a permission error, say) is no proof.
    public func isKnownAbsent() -> Bool {
        var info = stat()
        return lstat(url.path, &info) != 0 && errno == ENOENT
    }

    public func create() throws {
        let fm = FileManager.default
        try fm.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755])
        // Data.write throws the underlying Cocoa/POSIX error, which names the path and the reason.
        try Data().write(to: url)
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
    }

    public func remove() throws {
        do {
            try FileManager.default.removeItem(at: url)
        } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            return
        }
    }
}

/// Daemon-side bookkeeping: `disablesleep` goes back to 0 only when every holder has let go and
/// the 1 was set by us. One lock covers whole operations so "file before 1, 0 before removing the
/// file" never interleaves between XPC queues.
public final class SleepGuard: @unchecked Sendable {
    /// What the marker file means while it may exist.
    private enum Marker {
        case none
        /// We may have set 1: clean up with write 0, then remove.
        case owned
        /// A failed create's leftover that does not mean ownership: clean up with remove only.
        case stale
    }

    private let setting: SleepSetting
    private let store: OwnershipStore
    private let lock = NSLock()
    private var holders: Set<UUID> = []
    private var marker = Marker.none
    /// Set on the way out (SIGTERM or idle exit): no acquire may set 1 after the last reset.
    private var closed = false

    public init(setting: SleepSetting, store: OwnershipStore) {
        self.setting = setting
        self.store = store
    }

    public var isIdle: Bool {
        lock.lock(); defer { lock.unlock() }
        return holders.isEmpty && marker == .none
    }

    /// The marker means we may have set 1 and not yet confirmed the 0.
    public var ownsSetting: Bool {
        lock.lock(); defer { lock.unlock() }
        return marker == .owned
    }

    /// A cleanup failed and nobody holds: `retryPendingReset()` has work to do.
    public var hasPendingReset: Bool {
        lock.lock(); defer { lock.unlock() }
        return holders.isEmpty && marker != .none
    }

    public func acquire(_ holder: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        if closed { throw HelperError.commandFailed("shutting down") }
        if holders.isEmpty {
            // Read the real value even when owned: a failed earlier reset may have left it at 0.
            if try !setting.isDisabled() {
                do {
                    try store.create()
                } catch {
                    // Nothing reached pmset, so this claims no ownership (a pending reset keeps its own).
                    if marker != .owned {
                        marker = .stale
                        try? cleanUpIfUnheld()
                    }
                    throw error
                }
                // The write may land before failing: own it until a 0 is confirmed.
                marker = .owned
                do {
                    try setting.setDisabled(true)
                } catch {
                    try? cleanUpIfUnheld()
                    throw error
                }
            } else if marker == .none, store.exists() {
                marker = .owned
            }
        }
        holders.insert(holder)
    }

    public func release(_ holder: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        holders.remove(holder)
        try cleanUpIfUnheld()
    }

    public func releaseAll() throws {
        lock.lock(); defer { lock.unlock() }
        holders.removeAll()
        try cleanUpIfUnheld()
    }

    /// `releaseAll()` that also closes the guard, so an acquire racing the exit cannot set 1.
    /// Closed even when the reset fails (the marker then stays for `recoverAtStart`).
    public func shutdown() throws {
        lock.lock(); defer { lock.unlock() }
        closed = true
        holders.removeAll()
        try cleanUpIfUnheld()
    }

    /// `shutdown()` on the way out (SIGTERM), retried after a failure, and over within `budget`
    /// whatever happens: each attempt runs on its own thread and is waited for only until the
    /// budget is spent, because one can wait for the lock behind a slow pmset and then run
    /// its own (each up to ~19 s with the runner's timeout and kill). No attempt or pause
    /// starts once it is spent. Returns whether the reset is done; if not, the marker stays
    /// for `recoverAtStart`, and an abandoned attempt may still finish before the exit.
    public func shutdown(attempts: Int, pause: TimeInterval, within budget: TimeInterval) -> Bool {
        let log = Logger(subsystem: HelperIDs.helper, category: "daemon")
        let deadline = DispatchTime.now() + budget
        for attempt in 1...attempts {
            let done = DispatchSemaphore(value: 0)
            let failure = ShutdownFailure()
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try self.shutdown()
                } catch {
                    failure.message = HelperError.message(for: error)
                }
                done.signal()
            }
            guard done.wait(timeout: deadline) == .success else {
                log.error("release on SIGTERM still running (\(attempt)/\(attempts)) when the time ran out")
                return false
            }
            guard let message = failure.message else { return true }
            log.error("release on SIGTERM failed (\(attempt)/\(attempts)): \(message, privacy: .public)")
            guard attempt < attempts, DispatchTime.now() + pause < deadline else { return false }
            if pause > 0 { Thread.sleep(forTimeInterval: pause) }
        }
        return false
    }

    /// Closes the guard if nothing is held or pending; returns whether it did (then the daemon
    /// may exit without leaving anything behind). Never waits: while another call holds the
    /// lock (it may be inside pmset for seconds) it returns false and the caller tries later.
    public func shutdownIfIdle() -> Bool {
        guard lock.try() else { return false }
        defer { lock.unlock() }
        guard holders.isEmpty, marker == .none else { return false }
        closed = true
        return true
    }

    /// Runs `body` under the guard's lock, so no acquire or reset interleaves with it. Refused
    /// while anyone holds: the 0.2.0 cleanup writes `disablesleep 0` and would end their session.
    public func performWhileUnheld<T>(_ body: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        if closed { throw HelperError.commandFailed("shutting down") }
        guard holders.isEmpty else { throw HelperError.commandFailed("busy: closed-lid mode is active") }
        return try body()
    }

    /// Call only at daemon start, before accepting connections.
    public func recoverAtStart() throws {
        lock.lock(); defer { lock.unlock() }
        guard store.exists() else { return }
        // A 0 already in place needs no second write: only the marker is left to remove.
        marker = (try? setting.isDisabled()) == false ? .stale : .owned
        try cleanUpIfUnheld()
    }

    /// Repeats a cleanup that failed earlier; does nothing unless one is pending and nobody holds.
    public func retryPendingReset() throws {
        lock.lock(); defer { lock.unlock() }
        try cleanUpIfUnheld()
    }

    /// The only place a marker is cleared: after a confirmed 0 (when owned) and a successful remove.
    private func cleanUpIfUnheld() throws {
        guard holders.isEmpty else { return }
        switch marker {
        case .none: return
        case .owned:
            try setting.setDisabled(false)
            // The 0 is confirmed: a failing remove below must not write it again.
            marker = .stale
            try store.remove()
        case .stale:
            try store.remove()
        }
        marker = .none
    }
}

/// One shutdown attempt's error, written on its thread and read after its semaphore.
private final class ShutdownFailure: @unchecked Sendable {
    private let lock = NSLock()
    private var _message: String?
    var message: String? {
        get { lock.withLock { _message } }
        set { lock.withLock { _message = newValue } }
    }
}
