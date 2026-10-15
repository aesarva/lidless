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

public protocol PrivilegedBackend: Sendable {
    func status() -> HelperStatus
    func install() throws
    func uninstall() throws
    func setSleepDisabled(_ disabled: Bool) throws
    func isSleepDisabled() throws -> Bool
}
