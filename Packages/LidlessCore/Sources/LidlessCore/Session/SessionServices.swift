import Foundation

/// `acquire` replaces the currently held assertions.
@MainActor public protocol SleepAssertionService: AnyObject {
    func acquire(keepDisplayOn: Bool) throws
    func release()
}

public enum WakeNotification: Equatable, Sendable {
    case endingSoon(endsAt: Date)
    case sessionEnded(StopReason)
    case lidModeSuspended(SafetyReason)
    case assertionFailed(String)
}

@MainActor public protocol Notifier: AnyObject {
    func post(_ n: WakeNotification)
    func cancelEndingSoon()
}

@MainActor public protocol SettingsStore: AnyObject {
    func load() -> LidlessSettings
    func save(_ s: LidlessSettings)
}

public enum StartBlock: Equatable, Sendable {
    case lowBattery(threshold: Int)
}

/// Screen control used when the lid closes in closed-lid mode.
@MainActor public protocol DisplayControlling: AnyObject {
    /// True when a display other than the built-in one is active (clamshell with a monitor).
    func hasExternalDisplay() -> Bool
    /// Turns the displays off now; the system keeps running.
    func sleepDisplayNow()
}

/// Does nothing; for contexts without a real display (previews, tests that do not care).
@MainActor public final class NoDisplayControl: DisplayControlling {
    public init() {}
    public func hasExternalDisplay() -> Bool { false }
    public func sleepDisplayNow() {}
}
