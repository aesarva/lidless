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
