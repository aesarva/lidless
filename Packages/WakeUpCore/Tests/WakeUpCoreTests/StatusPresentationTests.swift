import Testing
import Foundation
@testable import WakeUpCore

struct StatusPresentationTests {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    @Test func formatRemaining() {
        #expect(StatusPresentation.formatRemaining(3480) == "0:58")
        #expect(StatusPresentation.formatRemaining(3599) == "1:00")
        #expect(StatusPresentation.formatRemaining(59) == "0:01")
        #expect(StatusPresentation.formatRemaining(0) == "0:00")
        #expect(StatusPresentation.formatRemaining(90000) == "25:00")
        #expect(StatusPresentation.formatRemaining(-5) == "0:00")
    }

    private func glyph(_ state: SessionState, attention: SafetyReason? = nil) -> IconGlyph {
        StatusPresentation.make(state: state, attention: attention, showTimerText: false, now: t0).glyph
    }

    @Test func glyphPriority() {
        let lidTimer = SessionState.active(Session(startedAt: t0, endsAt: t0 + 3600, lidModeActive: true))
        let timer = SessionState.active(Session(startedAt: t0, endsAt: t0 + 3600))
        let open = SessionState.active(Session(startedAt: t0))
        #expect(glyph(lidTimer, attention: .thermal) == .attention)
        #expect(glyph(lidTimer) == .lid)
        #expect(glyph(timer) == .timer)
        #expect(glyph(open) == .active)
        #expect(glyph(.off) == .off)
        #expect(glyph(.off, attention: .lowBattery) == .attention)
    }

    @Test func progressAndText() {
        let s = SessionState.active(Session(startedAt: t0, endsAt: t0 + 3600))
        let now = t0 + 900
        let on = StatusPresentation.make(state: s, attention: nil, showTimerText: true, now: now)
        #expect(on.progress == 0.75)
        #expect(on.timerText == "0:45")
        let off = StatusPresentation.make(state: s, attention: nil, showTimerText: false, now: now)
        #expect(off.timerText == nil)
        let open = StatusPresentation.make(state: .active(Session(startedAt: t0)), attention: nil, showTimerText: true, now: now)
        #expect(open.progress == nil)
        #expect(open.timerText == nil)
    }

    @Test func degenerateRangeAndClamping() {
        let bad = SessionState.active(Session(startedAt: t0, endsAt: t0))
        #expect(StatusPresentation.make(state: bad, attention: nil, showTimerText: false, now: t0).progress == 0)
        let s = SessionState.active(Session(startedAt: t0, endsAt: t0 + 100))
        #expect(StatusPresentation.make(state: s, attention: nil, showTimerText: false, now: t0 + 500).progress == 0)
        #expect(StatusPresentation.make(state: s, attention: nil, showTimerText: false, now: t0 - 50).progress == 1)
    }
}
