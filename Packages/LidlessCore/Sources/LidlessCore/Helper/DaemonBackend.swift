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
    /// How long a re-registration waits for launchd to confirm the old daemon is gone.
    private let unregisterWait: TimeInterval
    private let log = Logger(subsystem: HelperIDs.app, category: "helper")
    private let lock = NSLock()
    /// What the last `refreshInfo()` found wrong with an enabled daemon; nil until one does.
    private var infoError: String?
    /// Where the once-per-launch re-registration of a daemon that failed a check stands. A
    /// step that failed is retried by the next `refreshInfo()`, not forbidden for the launch.
    private enum Reregistration { case none, unregisterPending, registerPending, done }
    private var reregistration = Reregistration.none
    /// Why the pending re-registration began (the failed check).
    private var reregistrationReason = ""
    /// The `unregister` of the pending re-registration that launchd has not confirmed (a wait
    /// timed out): the next attempt waits for this one instead of issuing another. Dropped
    /// by uninstall().
    private var outstandingUnregister: PendingUnregister?
    /// The user removed the helper: no automatic re-registration until the next `install()`.
    private var userRemoved = false
    /// Bumped by install() and uninstall(): a refresh that began before one does not report.
    private var registrationGeneration: UInt64 = 0
    /// Held across every registration change (install, uninstall, unregister + register), so a
    /// background re-registration can never undo the user's uninstall.
    private let mutationLock = NSLock()

    public init(registration: HelperRegistration, client: HelperClient?, appVersion: String,
                legacy: LegacyHelperCleaner = LegacyHelperCleaner(), verifyDelay: TimeInterval = 1,
                unregisterWait: TimeInterval = 10) {
        self.registration = registration
        self.client = client
        self.appVersion = appVersion
        self.legacy = legacy
        self.verifyDelay = verifyDelay
        self.unregisterWait = unregisterWait
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
        case .notRegistered, .notFound:
            // Unregistered by a re-registration that is still to be completed: say why.
            return lock.withLock { reregistrationPending ? infoError : nil }.map { .error($0) } ?? .notInstalled
        case .requiresApproval: return .needsApproval
        case .enabled: return lock.withLock { infoError }.map { .error($0) } ?? .installed
        }
    }

    public func refreshInfo() {
        let startedIn = lock.withLock { registrationGeneration }
        guard let client else { return }
        let problem: String?
        if lock.withLock({ reregistrationPending }) {
            // Unregistered (or never confirmed) by a re-registration that did not finish.
            problem = reregister(client, because: lock.withLock { reregistrationReason }, retry: true)
        } else if registration.status == .enabled {
            problem = check(client).flatMap { reregister(client, because: $0) }
        } else {
            return
        }
        lock.withLock {
            // The user installed or removed the helper meanwhile: this is about the old one.
            guard registrationGeneration == startedIn else { return }
            if let problem { log.error("helper: \(problem, privacy: .public)") }
            infoError = problem
        }
    }

    /// Call under `lock`.
    private var reregistrationPending: Bool {
        reregistration == .unregisterPending || reregistration == .registerPending
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

    private enum Outcome { case reregistered, refused, alreadyDone }

    /// An enabled daemon that fails a check: one left over from another app version (an
    /// in-place update), one that drops the connection unanswered, or a job launchd removed
    /// after it kept failing while SMAppService still reports it enabled (info() only times
    /// out). Re-register so launchd starts the bundled one, then check the replacement:
    /// unregister, wait for launchd to confirm the old daemon is gone, register. A step that
    /// fails is retried from there by the next call (`refreshInfo()`, `install()`); once the
    /// whole sequence has gone through, it is not repeated in this launch. Unregistering
    /// sends the old daemon SIGTERM, which interrupts the client's connection; the client
    /// drops it and the next call opens a new one, so no explicit reconnect is needed.
    /// Returns the problem left, if any.
    private func reregister(_ client: HelperClient, because failure: String, retry: Bool = false) -> String? {
        var problem = failure
        let outcome: Outcome = mutationLock.withLock {
            // The user's uninstall may have run between info() and here.
            let enabled = registration.status == .enabled
            let allowed = lock.withLock { () -> Outcome? in
                guard !userRemoved else { return .refused }
                switch reregistration {
                case .none:
                    guard enabled else { return .refused }
                    reregistration = .unregisterPending
                    reregistrationReason = failure
                case .unregisterPending, .registerPending: break
                case .done: return .alreadyDone
                }
                return nil
            }
            if let allowed { return allowed }
            log.notice("\(failure, privacy: .public): re-registering")
            do {
                try finishReregistration()
            } catch {
                problem = "\(failure); re-registering failed: \(Self.describe(error))"
                return .refused
            }
            return .reregistered
        }
        switch outcome {
        case .refused: return problem
        // Another refresh finished it meanwhile; `failure` may be a stale reason.
        case .alreadyDone: return retry ? check(client) : failure
        case .reregistered: break
        }
        for _ in 0..<Self.verifyAttempts {
            if verifyDelay > 0 { Thread.sleep(forTimeInterval: verifyDelay) }
            guard let message = check(client) else { return nil }
            problem = "after re-registering: \(message)"
        }
        return problem
    }

    private static func describe(_ error: Error) -> String {
        (error as? HelperError)?.message ?? error.localizedDescription
    }

    /// The pending steps of a re-registration, from where the last attempt stopped; on
    /// failure the state stays, so the next attempt resumes. Call under `mutationLock`.
    private func finishReregistration() throws {
        if lock.withLock({ reregistration }) == .unregisterPending {
            try awaitUnregister()
            lock.withLock { reregistration = .registerPending }
        }
        try registerAfterUnregister()
        lock.withLock { reregistration = .done }
    }

    /// Returns once launchd no longer has the old daemon. Waits for an `unregister` that is
    /// still outstanding rather than submitting a second one, which would fail on a job that
    /// is already gone. Call under `mutationLock`.
    private func awaitUnregister() throws {
        let gone = { (status: RegistrationStatus) in status == .notRegistered || status == .notFound }
        if gone(registration.status) {
            lock.withLock { outstandingUnregister = nil }
            return
        }
        let pending = lock.withLock { outstandingUnregister } ?? registration.startUnregister()
        lock.withLock { outstandingUnregister = pending }
        guard let result = pending.wait(timeout: unregisterWait) else {
            throw HelperError.installFailed("unregister timed out")
        }
        lock.withLock { outstandingUnregister = nil }
        if case .failure(let error) = result, !gone(registration.status) { throw error }
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
        // An unfinished re-registration is resumed, not bypassed: its unregister may still
        // be outstanding, and a failure here must leave it pending.
        let pending = lock.withLock { () -> Bool in
            userRemoved = false
            registrationGeneration += 1
            if !reregistrationPending { infoError = nil }
            return reregistrationPending
        }
        do {
            if pending { try finishReregistration() } else { try registration.register() }
            lock.withLock {
                infoError = nil
                if pending { reregistration = .none }
            }
        } catch {
            // register() throws while the user has not allowed the daemon yet: show them where.
            guard registration.status == .requiresApproval else {
                throw HelperError.installFailed(Self.describe(error))
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
            reregistration = .none
            outstandingUnregister = nil
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
