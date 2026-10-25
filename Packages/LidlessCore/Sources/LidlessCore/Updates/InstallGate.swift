/// Ответ Sparkle «ставить» отдаётся только при открытой крышке (spec §4): установка перезапускает приложение.
@MainActor
public final class InstallGate {
    private var pending: (() -> Void)?

    public init() {}

    /// Отдаёт reply сразу, если lidOpen; иначе хранит и возвращает false.
    @discardableResult
    public func ready(lidOpen: Bool, reply: @escaping () -> Void) -> Bool {
        if lidOpen {
            pending = nil
            reply()
            return true
        }
        pending = reply
        return false
    }

    /// Крышка открыта: отдать сохранённый reply (один раз). true — отдан именно сейчас.
    @discardableResult
    public func lidOpened() -> Bool {
        guard let reply = pending else { return false }
        pending = nil
        reply()
        return true
    }

    /// Dismiss: забыть reply.
    public func cancel() { pending = nil }
}
