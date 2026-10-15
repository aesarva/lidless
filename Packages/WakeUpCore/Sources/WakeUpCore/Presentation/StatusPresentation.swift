import Foundation

public enum IconGlyph: String, Sendable { case off, active, timer, lid, attention }

public struct StatusPresentation: Equatable, Sendable {
    public let glyph: IconGlyph
    /// Доля ОСТАВШЕГОСЯ времени 0...1, только для сессии с endsAt.
    public let progress: Double?
    /// Только showTimerText && active && endsAt != nil.
    public let timerText: String?

    public init(glyph: IconGlyph, progress: Double?, timerText: String?) {
        self.glyph = glyph
        self.progress = progress
        self.timerText = timerText
    }

    public static func make(
        state: SessionState,
        attention: SafetyReason?,
        showTimerText: Bool,
        now: Date
    ) -> StatusPresentation {
        guard case .active(let session) = state else {
            return StatusPresentation(glyph: attention != nil ? .attention : .off, progress: nil, timerText: nil)
        }

        var progress: Double?
        var text: String?
        if let endsAt = session.endsAt {
            let total = endsAt.timeIntervalSince(session.startedAt)
            let remaining = endsAt.timeIntervalSince(now)
            if total > 0 {
                progress = min(1, max(0, remaining / total))
            } else {
                progress = 0
            }
            if showTimerText { text = formatRemaining(remaining) }
        }

        let glyph: IconGlyph
        if attention != nil {
            glyph = .attention
        } else if session.lidModeActive {
            glyph = .lid
        } else if session.endsAt != nil {
            glyph = .timer
        } else {
            glyph = .active
        }
        return StatusPresentation(glyph: glyph, progress: progress, timerText: text)
    }

    /// Округление вверх до минут, "H:MM"; только цифры и ':' (не зависит от локали).
    public static func formatRemaining(_ seconds: TimeInterval) -> String {
        let minutes = max(0, Int((seconds / 60).rounded(.up)))
        let mm = minutes % 60
        return "\(minutes / 60):\(mm < 10 ? "0" : "")\(mm)"
    }
}
