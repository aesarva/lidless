import Foundation

public enum HelperStatus: Equatable, Sendable {
    /// Not registered with launchd.
    case notInstalled
    /// Registered, waiting for the user to allow it in System Settings → Login Items.
    case needsApproval
    /// Registered and enabled; the daemon answered, or has not been asked yet.
    case installed
    /// A build without a Team ID: the daemon would refuse it, closed-lid mode is unavailable.
    case unsigned
    case error(String)
}

public enum HelperError: Error, Equatable {
    case commandFailed(String)
    case installFailed(String)
    /// The connection dropped with the call unanswered: the daemon refused this app's
    /// signature, could not decode the call (a daemon from another build), is not reachable
    /// or exited mid-call.
    case rejected(String)
}

public extension HelperError {
    /// The text alone, without the case name: XPC replies carry it and the client wraps it again.
    var message: String {
        switch self {
        case .commandFailed(let text), .installFailed(let text), .rejected(let text): text.isEmpty ? "command failed" : text
        }
    }

    /// `message` for a `HelperError`, the plain description for anything else.
    static func message(for error: Error) -> String {
        (error as? HelperError)?.message ?? String(describing: error)
    }
}

public protocol PrivilegedBackend: Sendable {
    /// Cheap enough for the main thread: never waits for the daemon.
    func status() -> HelperStatus
    /// Asks the daemon how it is doing and updates what `status()` reports. Blocks for up
    /// to the XPC timeout: never call it on the main thread.
    func refreshInfo()
    func install() throws
    func uninstall() throws
    /// Returns the generation of the daemon connection that carried the call (see `HelperClient`).
    @discardableResult func setSleepDisabled(_ disabled: Bool) throws -> UInt64
    func isSleepDisabled() throws -> Bool
    /// Whether any file of the 0.2.0 sudoers helper is still installed.
    func legacyHelperPresent() -> Bool
    /// Removes the 0.2.0 helper through the daemon; returns the removed paths. Fails while
    /// closed-lid mode is held or the daemon is exiting: retry later.
    func removeLegacyHelper() throws -> [String]
    func openSystemSettings()
}
