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
    private let appBuild: String
    private let legacy: LegacyHelperCleaner
    /// Pause before each check of a re-registered daemon (it restarts first).
    private let verifyDelay: TimeInterval
    private static let verifyAttempts = 3
    /// How long a re-registration waits for launchd to confirm the old daemon is gone.
    private let unregisterWait: TimeInterval
    /// Pause before asking a daemon that timed out once more.
    private let retryDelay: TimeInterval
    private let log = Logger(subsystem: HelperIDs.app, category: "helper")
    private let lock = NSLock()
    /// What the last `refreshInfo()` found wrong with an enabled daemon; nil until one does.
    private var infoError: String?
    /// The daemon's last successful answer for the current registration (`lastInfo()`).
    private var answer: HelperInfo?
    /// The daemon of the current registration answered with this app's version and build:
    /// `.installed` rather than `.checking`.
    private var verified = false
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
    /// Bumped by install(), uninstall() and each re-registration attempt: a check or refresh
    /// that began before one is about a daemon that is gone, so it does not report.
    private var registrationGeneration: UInt64 = 0
    /// Held across every registration change (install, uninstall, unregister + register), so a
    /// background re-registration can never undo the user's uninstall.
    private let mutationLock = NSLock()

    public init(registration: HelperRegistration, client: HelperClient?, appVersion: String,
                appBuild: String,
                legacy: LegacyHelperCleaner = LegacyHelperCleaner(), verifyDelay: TimeInterval = 1,
                unregisterWait: TimeInterval = 10, retryDelay: TimeInterval = 1) {
        self.registration = registration
        self.client = client
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.legacy = legacy
        self.verifyDelay = verifyDelay
        self.unregisterWait = unregisterWait
        self.retryDelay = retryDelay
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
        case .enabled:
            return lock.withLock { infoError.map { .error($0) } ?? (verified ? .installed : .checking) }
        }
    }

    public func lastInfo() -> HelperInfo? {
        lock.withLock { answer }
    }

    /// The client's errors as they are (`.timedOut`, `.rejected`, `.commandFailed`).
    public func freshInfo() throws -> HelperInfo {
        guard let client else { throw HelperError.commandFailed(Self.unsignedMessage) }
        return try client.info()
    }

    public func refreshInfo() {
        // Advanced by this refresh's own re-registration: the result is about the replacement.
        var generation = lock.withLock { registrationGeneration }
        guard let client else { return }
        let problem: String?
        if lock.withLock({ reregistrationPending }) {
            // Unregistered (or never confirmed) by a re-registration that did not finish.
            problem = reregister(client, because: lock.withLock { reregistrationReason }, generation: &generation,
                                 retry: true)
        } else if registration.status == .enabled {
            if let failure = check(client, startedIn: generation) {
                problem = failure.callsForReregistration
                    ? reregister(client, because: failure.message, generation: &generation) : failure.message
            } else {
                problem = nil
            }
        } else {
            return
        }
        lock.withLock {
            // The user installed or removed the helper, or another refresh re-registered it,
            // meanwhile: this is about the old one.
            guard registrationGeneration == generation else { return }
            if let problem { log.error("helper: \(problem, privacy: .public)") }
            infoError = problem
        }
    }

    /// Call under `lock`.
    private var reregistrationPending: Bool {
        reregistration == .unregisterPending || reregistration == .registerPending
    }

    /// Why an enabled daemon failed a check. Only a daemon from another build or one that
    /// cannot be reached is re-registered; one that answers with an error is not.
    private enum Failure {
        /// Another version or build.
        case mismatch(String)
        /// The connection dropped with the call unanswered (`HelperError.rejected`).
        case dropped(String)
        /// No reply twice in a row.
        case timedOut
        /// The daemon answered with an error (pmset -g failed), or anything else.
        case failed(String)

        var message: String {
            switch self {
            case .mismatch(let text), .dropped(let text), .failed(let text): text
            case .timedOut: HelperError.timedOut.message
            }
        }

        var callsForReregistration: Bool {
            if case .failed = self { return false }
            return true
        }
    }

    /// What is wrong with the enabled daemon, or nil when it answers with this app's version
    /// and build. The answer counts for the registration of `generation` only.
    private func check(_ client: HelperClient, startedIn generation: UInt64) -> Failure? {
        let info: HelperInfo
        do {
            info = try infoRetryingTimeout(client)
        } catch HelperError.rejected(let message) {
            // Most likely a daemon from another build whose interface differs.
            return .dropped("helper dropped the connection: \(message)")
        } catch HelperError.timedOut {
            return .timedOut
        } catch {
            return .failed(HelperError.message(for: error))
        }
        lock.withLock {
            // The user installed or removed the helper meanwhile: this is about the old one.
            guard registrationGeneration == generation else { return }
            answer = info
            verified = info.version == appVersion && info.build == appBuild
        }
        if info.version != appVersion {
            return .mismatch("helper version \(info.version) does not match Lidless \(appVersion)")
        }
        if info.build != appBuild {
            return .mismatch("helper build \(info.build) does not match Lidless build \(appBuild)")
        }
        return nil
    }

    /// A single timeout may be a daemon that is busy or just starting: ask once more.
    private func infoRetryingTimeout(_ client: HelperClient) throws -> HelperInfo {
        do {
            return try client.info()
        } catch HelperError.timedOut {
            if retryDelay > 0 { Thread.sleep(forTimeInterval: retryDelay) }
            return try client.info()
        }
    }

    private enum Outcome { case reregistered, refused, alreadyDone, stale }

    /// An enabled daemon that fails a check: one left over from another app version or build
    /// (an in-place update), one that drops the connection unanswered, or a job launchd
    /// removed after it kept failing while SMAppService still reports it enabled (info() only
    /// times out, twice in a row). Re-register so launchd starts the bundled one, then check
    /// the replacement: unregister, wait for launchd to confirm the old daemon is gone,
    /// register. A step that fails is retried from there by the next call (`refreshInfo()`,
    /// `install()`); once the whole sequence has gone through, it is not repeated in this
    /// launch. Unregistering sends the old daemon SIGTERM, which interrupts the client's
    /// connection; the client drops it and the next call opens a new one, so no explicit
    /// reconnect is needed. `generation` is the registration the failed check was about; the
    /// replacement's is passed back. Returns the problem left, if any.
    private func reregister(_ client: HelperClient, because failure: String, generation: inout UInt64,
                            retry: Bool = false) -> String? {
        var problem = failure
        let checked = generation
        let outcome: Outcome = mutationLock.withLock {
            // The user's uninstall may have run between info() and here.
            let enabled = registration.status == .enabled
            let allowed = lock.withLock { () -> Outcome? in
                // An install, uninstall or another re-registration since the check: the failure
                // is about a daemon that is gone, not the current one.
                guard registrationGeneration == checked else { return .stale }
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
            // Read back under `mutationLock`, so it is this attempt's, whether or not it failed.
            defer { generation = lock.withLock { registrationGeneration } }
            do {
                try finishReregistration()
            } catch {
                problem = "\(failure); re-registering failed: \(HelperError.message(for: error))"
                return .refused
            }
            return .reregistered
        }
        switch outcome {
        case .stale: return nil
        case .refused: return problem
        // Another refresh finished it meanwhile; `failure` may be a stale reason.
        case .alreadyDone: return retry ? check(client, startedIn: generation)?.message : failure
        case .reregistered: break
        }
        for _ in 0..<Self.verifyAttempts {
            if verifyDelay > 0 { Thread.sleep(forTimeInterval: verifyDelay) }
            guard let failure = check(client, startedIn: generation) else { return nil }
            problem = "after re-registering: \(failure.message)"
        }
        return problem
    }

    /// The pending steps of a re-registration, from where the last attempt stopped; on
    /// failure the state stays, so the next attempt resumes. Call under `mutationLock`.
    private func finishReregistration() throws {
        // The old daemon's answer, and any still on its way, is not about the replacement:
        // checking until it answers.
        lock.withLock {
            registrationGeneration += 1
            answer = nil
            verified = false
        }
        if lock.withLock({ reregistration }) == .unregisterPending {
            try awaitUnregister()
            lock.withLock { reregistration = .registerPending }
        }
        do {
            try registerAfterUnregister()
        } catch {
            // Waiting for the user's approval: not for retries to settle, install()'s flow does.
            guard registration.status == .requiresApproval else { throw error }
        }
        lock.withLock { reregistration = .done }
    }

    /// Returns once launchd no longer has the old daemon. An `unregister` that is still
    /// outstanding is always waited for, whatever the status says (register() before its
    /// completion fails or races the removal), and never submitted a second time, which would
    /// fail on a job that is already gone. Only with none outstanding does a status of
    /// not registered stand for confirmation. Call under `mutationLock`.
    private func awaitUnregister() throws {
        let gone = { (status: RegistrationStatus) in status == .notRegistered || status == .notFound }
        var pending = lock.withLock { outstandingUnregister }
        if pending == nil {
            if gone(registration.status) { return }
            pending = registration.startUnregister()
            lock.withLock { outstandingUnregister = pending }
        }
        guard let result = pending?.wait(timeout: unregisterWait) else {
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
            } catch where attempt < Self.verifyAttempts && registration.status != .requiresApproval {
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
            answer = nil
            verified = false
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
                throw HelperError.installFailed(HelperError.message(for: error))
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
            answer = nil
            verified = false
            userRemoved = true
            reregistration = .none
            outstandingUnregister = nil
            registrationGeneration += 1
        }
        guard registration.status != .notRegistered else { return }
        do {
            try registration.unregister()
        } catch {
            throw HelperError.installFailed(HelperError.message(for: error))
        }
    }

    /// The hold is taken under `mutationLock`: no install, uninstall or re-registration can
    /// replace the daemon between the verification check and the call.
    @discardableResult
    public func setSleepDisabled(_ disabled: Bool) throws -> UInt64 {
        guard disabled else { return try withClient { try $0.setSleepDisabled(false) } }
        return try mutationLock.withLock {
            guard status() == .installed else { throw HelperError.notReady }
            return try withClient { try $0.setSleepDisabled(true) }
        }
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
