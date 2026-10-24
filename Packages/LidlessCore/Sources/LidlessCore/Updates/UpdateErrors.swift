/// Разбор ошибок Sparkle. Коды — из SUErrors.h; `sparkleCode` равен nil, если ошибка не из домена Sparkle.
public enum UpdateErrors {
    static let noUpdate = 1001
    static let runningFromDiskImage = 1003
    static let runningTranslocated = 1005
    static let installationCanceled = 4007

    /// Запуск из образа DMG или после App Translocation — не сбой, а повод перенести приложение.
    public static func event(sparkleCode: Int?, message: String, userInitiated: Bool) -> UpdateEvent {
        switch sparkleCode {
        case runningFromDiskImage, runningTranslocated: .locationUnsupported
        default: .error(message: message, userInitiated: userInitiated)
        }
    }

    public enum CycleOutcome: Equatable, Sendable {
        case succeeded
        /// Пользователь отменил запрос пароля администратора: обновление никуда не делось.
        case installCanceled
        case failed
    }

    /// Итог цикла проверки. «Обновлений нет» Sparkle сообщает ошибкой, но это успешная проверка.
    public static func cycleOutcome(failed: Bool, sparkleCode: Int?) -> CycleOutcome {
        guard failed else { return .succeeded }
        switch sparkleCode {
        case noUpdate: return .succeeded
        case installationCanceled: return .installCanceled
        default: return .failed
        }
    }
}
