import Foundation

public enum SafetyReason: String, Codable, Equatable, Sendable {
    case lowBattery, thermal, lidOnBatteryLimit, helperUnavailable
}

public enum StopReason: Equatable, Sendable {
    case user, timerExpired, safety(SafetyReason), appQuit, assertionFailed
}

public struct Session: Equatable, Sendable {
    /// Stays the same for the whole session, across restart and extend (startedAt does not).
    public let id: UUID
    public var startedAt: Date
    public var endsAt: Date?
    public var keepDisplayOn: Bool
    /// disablesleep=1 установлен нами
    public var lidModeActive: Bool
    /// Режим крышки нужен, но помощник ещё не подтвердил удержание («Включается…»).
    public var lidModePending: Bool
    /// момент последнего успешного включения
    public var lidModeEnabledAt: Date?
    public var lidModeSuspendedReason: SafetyReason?
    /// true → предупреждение не слать
    public var endingSoonNotified: Bool

    public init(
        id: UUID = UUID(),
        startedAt: Date,
        endsAt: Date? = nil,
        keepDisplayOn: Bool = false,
        lidModeActive: Bool = false,
        lidModePending: Bool = false,
        lidModeEnabledAt: Date? = nil,
        lidModeSuspendedReason: SafetyReason? = nil,
        endingSoonNotified: Bool = false
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endsAt = endsAt
        self.keepDisplayOn = keepDisplayOn
        self.lidModeActive = lidModeActive
        self.lidModePending = lidModePending
        self.lidModeEnabledAt = lidModeEnabledAt
        self.lidModeSuspendedReason = lidModeSuspendedReason
        self.endingSoonNotified = endingSoonNotified
    }
}

public enum SessionState: Equatable, Sendable {
    case off
    case active(Session)
}

/// Closed-lid mode as it was before a helper removal (`SessionController.beginHelperRemoval`).
public struct LidModeRestorePoint: Equatable, Sendable {
    /// The session it belongs to (nil: none was running).
    public let sessionID: UUID?
    public let lidModeEnabled: Bool
    public let wasActive: Bool
    public let suspendedReason: SafetyReason?
}
