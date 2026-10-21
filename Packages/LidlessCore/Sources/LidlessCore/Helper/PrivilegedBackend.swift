import Foundation

public enum HelperStatus: Equatable, Sendable {
    case notInstalled, installed, error(String)
}

public enum HelperError: Error, Equatable {
    case cancelled
    case invalidUserName(String)
    case commandFailed(String)
    case installFailed(String)
}

public extension HelperError {
    /// The text alone, without the case name: XPC replies carry it and the client wraps it again.
    var message: String {
        switch self {
        case .cancelled: "cancelled"
        case .invalidUserName(let name): "invalid user name: \(name)"
        case .commandFailed(let text), .installFailed(let text): text.isEmpty ? "command failed" : text
        }
    }

    /// `message` for a `HelperError`, the plain description for anything else.
    static func message(for error: Error) -> String {
        (error as? HelperError)?.message ?? String(describing: error)
    }
}

public protocol PrivilegedBackend: Sendable {
    func status() -> HelperStatus
    func install() throws
    func uninstall() throws
    func setSleepDisabled(_ disabled: Bool) throws
    func isSleepDisabled() throws -> Bool
}
