import Foundation

@MainActor public protocol LidSleepControlling: AnyObject {
    func helperStatus() -> HelperStatus
    func enable() throws
    func disable() throws
    /// Undoes a `disablesleep 1` left behind by an earlier run. Returns false when that failed
    /// (disablesleep may still be 1).
    @discardableResult func recoverIfNeeded() -> Bool
}

@MainActor public final class LidSleepService: LidSleepControlling {
    private let backend: PrivilegedBackend
    /// This process turned disablesleep on and has not turned it off yet.
    private var enabledHere = false

    public init(backend: PrivilegedBackend) {
        self.backend = backend
    }

    public func helperStatus() -> HelperStatus { backend.status() }

    public func enable() throws {
        try backend.setSleepDisabled(true)
        enabledHere = true
    }

    public func disable() throws {
        guard enabledHere else { return }
        try backend.setSleepDisabled(false)
        enabledHere = false
    }

    /// Nothing to do here: the daemon undoes a leftover 1 when it starts and when this app's
    /// connection goes away.
    @discardableResult
    public func recoverIfNeeded() -> Bool { true }
}
