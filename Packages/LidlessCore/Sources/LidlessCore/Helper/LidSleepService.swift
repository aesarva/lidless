import Foundation

@MainActor public protocol LidSleepControlling: AnyObject {
    func helperStatus() -> HelperStatus
    func enable() throws
    func disable() throws
    /// Undoes a `disablesleep 1` left behind by an earlier run. Returns false when that failed
    /// (disablesleep may still be 1).
    @discardableResult func recoverIfNeeded() -> Bool
    /// The daemon connection of `generation` dropped. Returns true when that ended this
    /// app's hold (then nothing is held any more); false for nothing held or a report about a
    /// connection older than the one holding now.
    func connectionLost(generation: UInt64) -> Bool
}

@MainActor public final class LidSleepService: LidSleepControlling {
    private let backend: PrivilegedBackend
    /// Set while this process holds disablesleep on: the generation of the daemon connection
    /// that took the hold (the daemon releases it when that connection closes).
    private var heldGeneration: UInt64?

    public init(backend: PrivilegedBackend) {
        self.backend = backend
    }

    public func helperStatus() -> HelperStatus { backend.status() }

    public func enable() throws {
        heldGeneration = try backend.setSleepDisabled(true)
    }

    public func disable() throws {
        guard heldGeneration != nil else { return }
        try backend.setSleepDisabled(false)
        heldGeneration = nil
    }

    /// Nothing to do here: the daemon undoes a leftover 1 when it starts and when this app's
    /// connection goes away.
    @discardableResult
    public func recoverIfNeeded() -> Bool { true }

    /// Any connection up to the holding one counts: a newer one dropping means the holding
    /// one was already gone. After that a `disable()` does not call the daemon.
    public func connectionLost(generation: UInt64) -> Bool {
        guard let held = heldGeneration, generation >= held else { return false }
        heldGeneration = nil
        return true
    }
}
