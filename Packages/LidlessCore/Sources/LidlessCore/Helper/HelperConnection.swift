import Foundation
import os

/// The object exported to one client connection. `holder` names this connection in
/// `SleepGuard`; the connection's invalidation handler calls `markClosed()` and then releases it.
/// Methods run on XPC queues and may block for seconds inside pmset.
public final class HelperConnection: NSObject, HelperProtocol, @unchecked Sendable {
    private static let log = Logger(subsystem: HelperIDs.helper, category: "daemon")

    private let holder: UUID
    private let sleepGuard: SleepGuard
    private let cleaner: LegacyHelperCleaner
    private let version: String
    private let build: String
    /// Read by `info`; SleepGuard keeps its own.
    private let setting: SleepSetting
    /// Called after every `setSleepDisabled`, so the daemon can re-check its timers.
    private let onGuardChange: @Sendable () -> Void
    private let lock = NSLock()
    private var closed = false

    public init(
        holder: UUID, guard sleepGuard: SleepGuard, cleaner: LegacyHelperCleaner, version: String, build: String,
        setting: SleepSetting = PmsetSleepSetting(), onGuardChange: @escaping @Sendable () -> Void = {}
    ) {
        self.holder = holder
        self.sleepGuard = sleepGuard
        self.cleaner = cleaner
        self.version = version
        self.build = build
        self.setting = setting
        self.onGuardChange = onGuardChange
    }

    /// Call from the invalidation handler before releasing the holder.
    public func markClosed() {
        lock.withLock { closed = true }
    }

    private var isClosed: Bool { lock.withLock { closed } }

    public func setSleepDisabled(_ disabled: Bool, reply: @escaping @Sendable (String?) -> Void) {
        defer { onGuardChange() }
        let action = disabled ? "acquire" : "release"
        do {
            if disabled {
                if isClosed { throw HelperError.commandFailed("connection closed") }
                try sleepGuard.acquire(holder)
                // Invalidated while acquiring: its release may already have run, so let go
                // here or the holder would keep disablesleep 1 forever.
                if isClosed {
                    try sleepGuard.release(holder)
                    throw HelperError.commandFailed("connection closed")
                }
            } else {
                try sleepGuard.release(holder)
            }
            Self.log.notice("\(action, privacy: .public) \(self.holder, privacy: .public): ok")
            reply(nil)
        } catch {
            let message = HelperError.message(for: error)
            Self.log.error("\(action, privacy: .public) \(self.holder, privacy: .public) failed: \(message, privacy: .public)")
            reply(message)
        }
    }

    public func info(reply: @escaping @Sendable (String, String, Bool, Bool, String?) -> Void) {
        do {
            reply(version, build, try setting.isDisabled(), sleepGuard.ownsSetting, nil)
        } catch {
            let message = HelperError.message(for: error)
            Self.log.error("info: reading disablesleep failed: \(message, privacy: .public)")
            reply(version, build, false, sleepGuard.ownsSetting, message)
        }
    }

    public func removeLegacyHelper(reply: @escaping @Sendable ([String], String?) -> Void) {
        do {
            // Under the guard's lock and refused while lid mode is held: the cleanup writes 0.
            let removed = try sleepGuard.performWhileUnheld { try cleaner.clean() }
            Self.log.notice("0.2.0 cleanup removed \(removed, privacy: .public)")
            reply(removed, nil)
        } catch {
            let message = HelperError.message(for: error)
            Self.log.error("0.2.0 cleanup failed: \(message, privacy: .public)")
            reply([], message)
        }
    }
}
