import Foundation
import LidlessCore
import os

/// The object exported to one client connection. `holder` names this connection in
/// `SleepGuard`; the connection's invalidation handler releases it.
/// Methods run on XPC queues and may block for seconds inside pmset.
final class HelperConnection: NSObject, HelperProtocol {
    private static let log = Logger(subsystem: HelperIDs.helper, category: "daemon")

    private let holder: UUID
    private let sleepGuard: SleepGuard
    private let cleaner: LegacyHelperCleaner
    private let version: String
    /// Called after every `setSleepDisabled`, so the daemon can re-check its timers.
    private let onGuardChange: @Sendable () -> Void

    init(
        holder: UUID, guard sleepGuard: SleepGuard, cleaner: LegacyHelperCleaner, version: String,
        onGuardChange: @escaping @Sendable () -> Void = {}
    ) {
        self.holder = holder
        self.sleepGuard = sleepGuard
        self.cleaner = cleaner
        self.version = version
        self.onGuardChange = onGuardChange
    }

    func setSleepDisabled(_ disabled: Bool, reply: @escaping @Sendable (String?) -> Void) {
        defer { onGuardChange() }
        let action = disabled ? "acquire" : "release"
        do {
            if disabled {
                try sleepGuard.acquire(holder)
            } else {
                try sleepGuard.release(holder)
            }
            Self.log.notice("\(action, privacy: .public) \(self.holder, privacy: .public): ok")
            reply(nil)
        } catch {
            let message = String(describing: error)
            Self.log.error("\(action, privacy: .public) \(self.holder, privacy: .public) failed: \(message, privacy: .public)")
            reply(message)
        }
    }

    func info(reply: @escaping @Sendable (String, Bool, String?) -> Void) {
        do {
            reply(version, try PmsetSleepSetting().isDisabled(), nil)
        } catch {
            let message = String(describing: error)
            Self.log.error("info: reading disablesleep failed: \(message, privacy: .public)")
            reply(version, false, message)
        }
    }

    func removeLegacyHelper(reply: @escaping @Sendable ([String], String?) -> Void) {
        do {
            let removed = try cleaner.clean()
            Self.log.notice("0.2.0 cleanup removed \(removed, privacy: .public)")
            reply(removed, nil)
        } catch {
            let message = String(describing: error)
            Self.log.error("0.2.0 cleanup failed: \(message, privacy: .public)")
            reply([], message)
        }
    }
}
