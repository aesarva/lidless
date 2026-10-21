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
    private let log = Logger(subsystem: HelperIDs.app, category: "helper")
    private let lock = NSLock()
    /// What the last `refreshInfo()` found wrong with an enabled daemon; nil until one does.
    private var infoError: String?
    /// The once-per-launch re-registration after a version mismatch has been used.
    private var reregistered = false

    public init(registration: HelperRegistration, client: HelperClient?, appVersion: String,
                legacy: LegacyHelperCleaner = LegacyHelperCleaner()) {
        self.registration = registration
        self.client = client
        self.appVersion = appVersion
        self.legacy = legacy
    }

    /// Fires after the connection to the daemon dropped (timeout, idle exit, crash): whatever
    /// the daemon held for this app is released, so re-check and re-apply.
    public var onConnectionLost: (@Sendable () -> Void)? {
        get { client?.onConnectionLost }
        set { client?.onConnectionLost = newValue }
    }

    public func status() -> HelperStatus {
        guard client != nil else { return .unsigned }
        switch registration.status {
        case .notRegistered: return .notInstalled
        case .requiresApproval: return .needsApproval
        case .notFound: return .error("the helper is missing from the app bundle")
        case .enabled: return lock.withLock { infoError }.map { .error($0) } ?? .installed
        }
    }

    public func refreshInfo() {
        guard let client, registration.status == .enabled else { return }
        let problem: String?
        do {
            let info = try client.info()
            problem = info.version == appVersion ? nil : versionMismatch(info.version)
        } catch {
            problem = HelperError.message(for: error)
        }
        if let problem { log.error("helper: \(problem, privacy: .public)") }
        lock.withLock { infoError = problem }
    }

    /// A daemon left over from another app version (an in-place update): re-register once per
    /// launch so launchd starts the bundled one. Unregistering sends the old daemon SIGTERM,
    /// which interrupts the client's connection; the client drops it and the next call opens a
    /// new one, so no explicit reconnect is needed here. Returns the problem left, if any.
    private func versionMismatch(_ daemonVersion: String) -> String? {
        let first = lock.withLock { () -> Bool in
            defer { reregistered = true }
            return !reregistered
        }
        let mismatch = "helper version \(daemonVersion) does not match Lidless \(appVersion)"
        guard first else { return mismatch }
        log.notice("\(mismatch, privacy: .public): re-registering")
        do {
            try registration.unregister()
            try registration.register()
            return nil
        } catch {
            return "\(mismatch); re-registering failed: \(error.localizedDescription)"
        }
    }

    public func install() throws {
        guard client != nil else { throw HelperError.installFailed(Self.unsignedMessage) }
        lock.withLock { infoError = nil }
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
        lock.withLock { infoError = nil }
        guard registration.status != .notRegistered else { return }
        do {
            try registration.unregister()
        } catch {
            throw HelperError.installFailed(error.localizedDescription)
        }
    }

    public func setSleepDisabled(_ disabled: Bool) throws {
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
