import Foundation
import os
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
    /// Returns once launchd confirms the daemon is gone (the completion handler); throws when
    /// it does not within `timeout`, or reports an error.
    func unregisterAndWait(timeout: TimeInterval) throws
    func openSystemSettings()
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

    public func unregisterAndWait(timeout: TimeInterval) throws {
        let done = DispatchSemaphore(value: 0)
        let result = OSAllocatedUnfairLock<Error?>(initialState: nil)
        service.unregister { error in
            result.withLock { $0 = error }
            done.signal()
        }
        guard done.wait(timeout: .now() + timeout) == .success else {
            throw HelperError.installFailed("unregister timed out")
        }
        if let error = result.withLock({ $0 }) { throw error }
    }

    public func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
