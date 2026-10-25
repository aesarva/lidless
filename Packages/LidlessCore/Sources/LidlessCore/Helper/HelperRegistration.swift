import Foundation
import ServiceManagement

public enum RegistrationStatus: Equatable, Sendable {
    case notRegistered
    case enabled
    case requiresApproval
    case notFound
}

/// Registration of the privileged daemon with launchd (System Settings → Login Items).
public protocol HelperRegistration: Sendable {
    var status: RegistrationStatus { get }
    func register() throws
    func unregister() throws
    /// Starts `unregister(completionHandler:)`; the returned operation is what launchd's
    /// completion later resolves, however long that takes.
    func startUnregister() -> PendingUnregister
    func openSystemSettings()
}

/// An `unregister` that launchd has not confirmed yet. Kept across waits: a timeout only
/// stops waiting, the completion can still arrive later and is then not lost.
public final class PendingUnregister: @unchecked Sendable {
    private let lock = NSLock()
    private let arrived = DispatchSemaphore(value: 0)
    private var result: Result<Void, Error>?

    public init() {}

    /// The completion handler's call; only the first one counts.
    public func complete(_ error: Error?) {
        let first = lock.withLock { () -> Bool in
            guard result == nil else { return false }
            result = error.map { .failure($0) } ?? .success(())
            return true
        }
        if first { arrived.signal() }
    }

    /// The outcome once launchd reported it, nil while it is still outstanding after `timeout`.
    public func wait(timeout: TimeInterval) -> Result<Void, Error>? {
        if let done = lock.withLock({ result }) { return done }
        _ = arrived.wait(timeout: .now() + timeout)
        return lock.withLock { result }
    }
}

/// `SMAppService.daemon(plistName:)`; the plist lives in `Contents/Library/LaunchDaemons`.
public struct SMAppServiceRegistration: HelperRegistration {
    private let plistName: String

    public init(plistName: String = HelperIDs.plistName) {
        self.plistName = plistName
    }

    // SMAppService is not Sendable, so it is looked up per call (a cheap handle).
    private var service: SMAppService { SMAppService.daemon(plistName: plistName) }

    public var status: RegistrationStatus {
        switch service.status {
        case .notRegistered: .notRegistered
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        @unknown default: .notFound
        }
    }

    public func register() throws {
        try service.register()
    }

    public func unregister() throws {
        try service.unregister()
    }

    public func startUnregister() -> PendingUnregister {
        let pending = PendingUnregister()
        service.unregister { pending.complete($0) }
        return pending
    }

    public func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
