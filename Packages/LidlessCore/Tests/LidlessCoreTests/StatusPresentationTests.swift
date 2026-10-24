import Testing
import Foundation
@testable import LidlessCore

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

    @Test func formatElapsed() {
        #expect(StatusPresentation.formatElapsed(0) == "0:00")
        #expect(StatusPresentation.formatElapsed(59.9) == "0:59")
        #expect(StatusPresentation.formatElapsed(754) == "12:34")
        #expect(StatusPresentation.formatElapsed(3599) == "59:59")
        #expect(StatusPresentation.formatElapsed(3600) == "1:00:00")
        #expect(StatusPresentation.formatElapsed(4354) == "1:12:34")
        #expect(StatusPresentation.formatElapsed(-3) == "0:00")
        #expect(StatusPresentation.formatElapsed(.infinity) == "0:00")
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

    @Test func updateDotGivesWayToAttention() {
        func dot(_ state: SessionState, attention: SafetyReason? = nil, update: Bool) -> StatusPresentation {
            StatusPresentation.make(state: state, attention: attention, updateAvailable: update,
                                    showTimerText: false, now: t0)
        }
        let lid = SessionState.active(Session(startedAt: t0, lidModeActive: true))
        #expect(dot(.off, update: true).updateDot)
        #expect(dot(.off, update: true).glyph == .off)
        // On air the lamp stays: the dot sits on it.
        #expect(dot(lid, update: true).glyph == .lid)
        #expect(dot(lid, update: true).updateDot)
        #expect(!dot(.off, update: false).updateDot)
        // Both wanted: only the orange one is drawn.
        #expect(!dot(.off, attention: .lowBattery, update: true).updateDot)
        #expect(dot(.off, attention: .lowBattery, update: true).glyph == .attention)
        #expect(!dot(lid, attention: .thermal, update: true).updateDot)
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

    @Test func progressChangesInWholePercents() {
        let s = SessionState.active(Session(startedAt: t0, endsAt: t0 + 3 * 3600))
        let a = StatusPresentation.make(state: s, attention: nil, showTimerText: false, now: t0 + 1)
        let b = StatusPresentation.make(state: s, attention: nil, showTimerText: false, now: t0 + 2)
        #expect(a == b)
        #expect(a.progress == 1)
        let end = StatusPresentation.make(state: s, attention: nil, showTimerText: false, now: t0 + 3 * 3600 - 1)
        #expect(end.progress == 0.01)
    }

    @Test func degenerateRangeAndClamping() {
        let bad = SessionState.active(Session(startedAt: t0, endsAt: t0))
        #expect(StatusPresentation.make(state: bad, attention: nil, showTimerText: false, now: t0).progress == 0)
        let s = SessionState.active(Session(startedAt: t0, endsAt: t0 + 100))
        #expect(StatusPresentation.make(state: s, attention: nil, showTimerText: false, now: t0 + 500).progress == 0)
        #expect(StatusPresentation.make(state: s, attention: nil, showTimerText: false, now: t0 - 50).progress == 1)
    }
}
