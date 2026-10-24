import Foundation

/// Сеанс, переживающий перезапуск после обновления (spec §4). Пишется перед установкой, читается один раз при запуске.
public struct ResumeSnapshot: Codable, Equatable, Sendable {
    public var savedAt: Date
    public var startedAt: Date
    public var endsAt: Date?
    public var keepDisplayOn: Bool
    public var lidModeActive: Bool
    public var lidModeSuspendedReason: SafetyReason?
    public var lidModeEnabledAt: Date?

    /// Дольше этого перезапуск не считается продолжением сеанса.
    public static let maxAge: TimeInterval = 120

    public init(session: Session, savedAt: Date) {
        self.savedAt = savedAt
        startedAt = session.startedAt
        endsAt = session.endsAt
        keepDisplayOn = session.keepDisplayOn
        lidModeActive = session.lidModeActive
        // Режим крышки ещё ждал помощника: без причины это выглядело бы как намеренно выключенный.
        lidModeSuspendedReason = session.lidModeSuspendedReason
            ?? (session.lidModePending && !session.lidModeActive ? .helperUnavailable : nil)
        lidModeEnabledAt = session.lidModeEnabledAt
    }

    /// nil — не восстанавливать (старше maxAge или endsAt в прошлом).
    public func usable(now: Date) -> ResumeSnapshot? {
        guard now.timeIntervalSince(savedAt) <= Self.maxAge else { return nil }
        if let endsAt, endsAt <= now { return nil }
        return self
    }
}

public protocol ResumeStore: Sendable {
    func save(_ s: ResumeSnapshot)
    /// Читает и удаляет: снимок годится для одного запуска.
    func take() -> ResumeSnapshot?
}

public struct UserDefaultsResumeStore: ResumeStore {
    static let key = "resumeAfterUpdate"
    // UserDefaults потокобезопасен, но не помечен Sendable в этом SDK.
    nonisolated(unsafe) private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func save(_ s: ResumeSnapshot) {
        guard let data = try? JSONEncoder().encode(s) else { return }
        defaults.set(data, forKey: Self.key)
    }

    public func take() -> ResumeSnapshot? {
        defer { defaults.removeObject(forKey: Self.key) }
        guard let data = defaults.data(forKey: Self.key) else { return nil }
        return try? JSONDecoder().decode(ResumeSnapshot.self, from: data)
    }
}
