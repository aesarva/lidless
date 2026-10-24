import Foundation

/// Что панель, значок и настройки показывают об обновлении.
public enum UpdateState: Equatable, Sendable {
    case idle
    /// Только при ручной проверке: фоновая идёт молча.
    case checking
    /// Только после ручной проверки.
    case upToDate
    case available(version: String, notesURL: URL?)
    /// `progress` — доля 0…1; `nil`, пока сервер не назвал размер.
    case downloading(version: String, progress: Double?)
    case installing(version: String)
    /// Обновление готово, но ставить его при закрытой крышке нельзя: ждём, пока её откроют.
    case waitingForLid(version: String)
    case failed(message: String)
    /// Lidless запущен из образа DMG или из временной папки: Sparkle отсюда не обновляет.
    case needsMove
}

/// События обновлятеля (Sparkle), переведённые в наши термины.
public enum UpdateEvent: Equatable, Sendable {
    case checkStarted(userInitiated: Bool)
    case found(version: String, notesURL: URL?)
    case notFound(userInitiated: Bool)
    case downloadStarted
    case expectedLength(UInt64)
    case received(UInt64)
    /// Распаковка, готовность к установке и сама установка — для пользователя это один шаг.
    case installing
    /// Установка отложена до открытия крышки (ответ Sparkle придержан).
    case waitingForOpenLid
    case error(message: String, userInitiated: Bool)
    /// Sparkle отказался работать из-за расположения приложения (образ DMG, App Translocation).
    case locationUnsupported
    /// Фоновая проверка прошла без ошибок. Без обновления Sparkle не зовёт интерфейс, поэтому старый
    /// результат ручной проверки («ошибка», «последняя версия») иначе висел бы до следующего релиза.
    case backgroundCheckSucceeded
    /// Предложение провисело сутки и снято: Sparkle закроет сессию и проверит заново. Пока он не нашёл версию
    /// снова, кнопка «Установить» не работала бы — поэтому убираем её сразу.
    case offerExpired
    /// Sparkle закрыл сессию обновления.
    case dismissed
}

/// Состояние обновления и счётчики скачивания. Чистая модель: Sparkle только поставляет события.
public struct UpdateModel: Equatable, Sendable {
    public private(set) var state: UpdateState = .idle
    private var expected: UInt64?
    private var received: UInt64 = 0

    public init() {}

    /// Точка на значке: обновление есть и ещё не установлено. Ошибка ручной проверки не значит, что оно есть.
    public var showsBadge: Bool {
        switch state {
        case .available, .downloading, .installing, .waitingForLid: true
        default: false
        }
    }

    public mutating func apply(_ event: UpdateEvent) {
        switch event {
        case .checkStarted(let userInitiated):
            if userInitiated { state = .checking }
        case .found(let version, let notesURL):
            state = .available(version: version, notesURL: notesURL)
        case .notFound(let userInitiated):
            state = userInitiated ? .upToDate : .idle
        case .downloadStarted:
            expected = nil
            received = 0
            state = .downloading(version: version, progress: nil)
        case .expectedLength(let length):
            expected = length
            state = .downloading(version: version, progress: progress)
        case .received(let length):
            received &+= length
            state = .downloading(version: version, progress: progress)
        case .installing:
            state = .installing(version: version)
        case .waitingForOpenLid:
            state = .waitingForLid(version: version)
        case .error(let message, let userInitiated):
            state = userInitiated || isInstalling ? .failed(message: message) : .idle
        case .locationUnsupported:
            state = .needsMove
        case .offerExpired:
            if case .available = state { state = .idle }
        case .backgroundCheckSucceeded:
            switch state {
            case .failed, .upToDate: state = .idle
            default: break
            }
        case .dismissed:
            switch state {
            case .checking, .downloading, .installing, .waitingForLid: state = .idle
            default: break
            }
        }
    }

    private var version: String {
        switch state {
        case .available(let version, _), .downloading(let version, _), .installing(let version),
             .waitingForLid(let version): version
        default: ""
        }
    }

    private var progress: Double? {
        guard let expected, expected > 0 else { return nil }
        // Целыми процентами: состояние меняется не чаще сотни раз, а не на каждый пришедший кусок.
        return (min(1, Double(received) / Double(expected)) * 100).rounded(.down) / 100
    }

    private var isInstalling: Bool {
        switch state {
        case .downloading, .installing, .waitingForLid: true
        default: false
        }
    }
}

/// Можно ли обновлять приложение там, где оно лежит. Из образа DMG (том только для чтения) и после
/// App Translocation Sparkle молча отказывается даже проверять обновления — об этом говорим сами.
public enum UpdateLocation {
    public static func canUpdate(bundlePath: String, volumeIsReadOnly: Bool) -> Bool {
        !volumeIsReadOnly && !bundlePath.contains("/AppTranslocation/")
    }
}
