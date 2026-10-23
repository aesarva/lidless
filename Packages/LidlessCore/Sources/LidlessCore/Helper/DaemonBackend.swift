import Foundation
import os

/// `PrivilegedBackend` over the privileged daemon: registration through SMAppService,
/// commands over XPC. `client == nil` means a build without a Team ID (`.unsigned`): the
/// daemon would reject it, so registration is never touched and no connection is opened.
public final class DaemonBackend: PrivilegedBackend, @unchecked Sendable {
    private static let unsignedMessage = "closed-lid mode needs a signed build of Lidless"

    private let registration: HelperRegistration
    private let client: HelperClient?
    private let appVersion: String
    private let legacy: LegacyHelperCleaner
    /// Pause before each check of a re-registered daemon (it restarts first).
    private let verifyDelay: TimeInterval
    private static let verifyAttempts = 3
    private let log = Logger(subsystem: HelperIDs.app, category: "helper")
    private let lock = NSLock()
    /// What the last `refreshInfo()` found wrong with an enabled daemon; nil until one does.
    private var infoError: String?
    /// The once-per-launch re-registration of a daemon that failed a check has been used.
    private var reregistered = false
    /// The user removed the helper: no automatic re-registration until the next `install()`.
    private var userRemoved = false
    /// Bumped by install() and uninstall(): a refresh that began before one does not report.
    private var registrationGeneration: UInt64 = 0
    /// Held across every registration change (install, uninstall, unregister + register), so a
    /// background re-registration can never undo the user's uninstall.
    private let mutationLock = NSLock()

    public init(registration: HelperRegistration, client: HelperClient?, appVersion: String,
                legacy: LegacyHelperCleaner = LegacyHelperCleaner(), verifyDelay: TimeInterval = 1) {
        self.registration = registration
        self.client = client
        self.appVersion = appVersion
        self.legacy = legacy
        self.verifyDelay = verifyDelay
    }

    /// Fires with a connection's generation after it dropped (timeout, idle exit, crash): what
    /// the daemon held for that connection is released, so re-check and re-apply.
    public var onConnectionLost: (@Sendable (UInt64) -> Void)? {
        get { client?.onConnectionLost }
        set { client?.onConnectionLost = newValue }
    }

    public func status() -> HelperStatus {
        guard client != nil else { return .unsigned }
        switch registration.status {
        // SMAppService may report notFound for a daemon that was never registered; if the
        // plist really is missing, install() reports the error.
        case .notRegistered, .notFound: return .notInstalled
        case .requiresApproval: return .needsApproval
        case .enabled: return lock.withLock { infoError }.map { .error($0) } ?? .installed
        }
    }

    public func refreshInfo() {
        let startedIn = lock.withLock { registrationGeneration }
        guard let client, registration.status == .enabled else { return }
        let problem = check(client).flatMap { reregister(client, because: $0) }
        lock.withLock {
            // The user installed or removed the helper meanwhile: this is about the old one.
            guard registrationGeneration == startedIn else { return }
            if let problem { log.error("helper: \(problem, privacy: .public)") }
            infoError = problem
        }
    }

    /// What is wrong with the enabled daemon, or nil when it answers with this app's version.
    private func check(_ client: HelperClient) -> String? {
        do {
            let info = try client.info()
            if info.version == appVersion { return nil }
            return "helper version \(info.version) does not match Lidless \(appVersion)"
        } catch HelperError.rejected(let message) {
            // Most likely a daemon from another build whose interface differs.
            return "helper dropped the connection: \(message)"
        } catch {
            return HelperError.message(for: error)
        }
    }

    /// An enabled daemon that fails a check: one left over from another app version (an
    /// in-place update), one that drops the connection unanswered, or a job launchd removed
    /// after it kept failing while SMAppService still reports it enabled (info() only times
    /// out). Re-register once per launch so launchd starts the bundled one, then check the
    /// replacement. Unregistering sends the old daemon SIGTERM, which interrupts the client's
    /// connection; the client drops it and the next call opens a new one, so no explicit
    /// reconnect is needed. Returns the problem left, if any.
    private func reregister(_ client: HelperClient, because failure: String) -> String? {
        // nil: re-registered; otherwise why not.
        let refused: String? = mutationLock.withLock {
            let allowed = lock.withLock { () -> Bool in
                guard !userRemoved, !reregistered else { return false }
                reregistered = true
                return true
            }
            // The user's uninstall may have run between info() and here.
            guard allowed, registration.status == .enabled else { return failure }
            log.notice("\(failure, privacy: .public): re-registering")
            do {
                try registration.unregister()
                try registerAfterUnregister()
                return nil
            } catch {
                return "\(failure); re-registering failed: \(error.localizedDescription)"
            }
        }
        if let refused { return refused }
        var problem = failure
        for _ in 0..<Self.verifyAttempts {
            if verifyDelay > 0 { Thread.sleep(forTimeInterval: verifyDelay) }
            guard let message = check(client) else { return nil }
            problem = "after re-registering: \(message)"
        }
        return problem
    }

    /// register() right after unregister() fails with EPERM while launchd is still removing
    /// the old job: try up to `verifyAttempts` times, pausing in between.
    private func registerAfterUnregister() throws {
        for attempt in 1... {
            do {
                return try registration.register()
            } catch where attempt < Self.verifyAttempts {
                if verifyDelay > 0 { Thread.sleep(forTimeInterval: verifyDelay) }
            }
        }
    }

    public func install() throws {
        guard client != nil else { throw HelperError.installFailed(Self.unsignedMessage) }
        mutationLock.lock(); defer { mutationLock.unlock() }
        lock.withLock {
            infoError = nil
            userRemoved = false
            registrationGeneration += 1
        }
        do {
            try registration.register()
        } catch {
            // register() throws while the user has not allowed the daemon yet: show them where.
            guard registration.status == .requiresApproval else {
                throw HelperError.installFailed(error.localizedDescription)
            }
        }
        if registration.status == .requiresApproval { registration.openSystemSettings() }
    }

    /// launchd sends the daemon SIGTERM; it returns sleep to normal itself.
    public func uninstall() throws {
        guard client != nil else { throw HelperError.installFailed(Self.unsignedMessage) }
        mutationLock.lock(); defer { mutationLock.unlock() }
        lock.withLock {
            infoError = nil
            userRemoved = true
            registrationGeneration += 1
        }
        guard registration.status != .notRegistered else { return }
        do {
            try registration.unregister()
        } catch {
            throw HelperError.installFailed(error.localizedDescription)
        }
    }

    @discardableResult
    public func setSleepDisabled(_ disabled: Bool) throws -> UInt64 {
        try withClient { try $0.setSleepDisabled(disabled) }
    }

    public func isSleepDisabled() throws -> Bool {
        try withClient { try $0.info().sleepDisabled }
    }

    public func legacyHelperPresent() -> Bool {
        legacy.isPresent()
    }

    public func removeLegacyHelper() throws -> [String] {
        try withClient { try $0.removeLegacyHelper() }
    }

    public func openSystemSettings() {
        registration.openSystemSettings()
    }

    /// Every client failure surfaces as `HelperError.commandFailed`.
    private func withClient<T>(_ body: (HelperClient) throws -> T) throws -> T {
        guard let client else { throw HelperError.commandFailed(Self.unsignedMessage) }
        do {
            return try body(client)
        } catch let error as HelperError {
            throw HelperError.commandFailed(error.message)
        } catch {
            throw HelperError.commandFailed(String(describing: error))
        }
    }
}
