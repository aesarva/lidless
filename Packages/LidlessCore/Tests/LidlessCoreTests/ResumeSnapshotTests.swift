import Foundation
import Testing
@testable import LidlessCore

@Suite struct ResumeSnapshotTests {
    let t0 = Date(timeIntervalSince1970: 10_000)

    func snapshot(endsAt: Date? = nil, savedAt: Date? = nil) -> ResumeSnapshot {
        ResumeSnapshot(session: Session(startedAt: t0 - 600, endsAt: endsAt, keepDisplayOn: true),
                       savedAt: savedAt ?? t0)
    }

    @Test func freshSnapshotUsable() {
        let s = snapshot()
        #expect(s.usable(now: t0 + 59) == s)
    }

    @Test func oldSnapshotUnusable() {
        #expect(snapshot().usable(now: t0 + 121) == nil)
    }

    @Test func expiredEndUnusable() {
        #expect(snapshot(endsAt: t0 + 30).usable(now: t0 + 60) == nil)
        #expect(snapshot(endsAt: t0 + 90).usable(now: t0 + 60) != nil)
    }

    @Test func indefiniteUsable() {
        #expect(snapshot(endsAt: nil).usable(now: t0 + 60) != nil)
    }

    @Test func copiesSessionFields() {
        let session = Session(startedAt: t0, endsAt: t0 + 900, keepDisplayOn: true, lidModeActive: true,
                              lidModePending: true, lidModeEnabledAt: t0 + 5)
        let s = ResumeSnapshot(session: session, savedAt: t0 + 7)
        #expect(s.savedAt == t0 + 7 && s.startedAt == t0 && s.endsAt == t0 + 900)
        #expect(s.keepDisplayOn && s.lidModeActive && s.lidModeEnabledAt == t0 + 5)
        #expect(s.lidModeSuspendedReason == nil)
    }

    @Test func takeReadsOnce() {
        let defaults = UserDefaults(suiteName: "ResumeSnapshotTests.\(UUID())")!
        let store = UserDefaultsResumeStore(defaults: defaults)
        let s = snapshot()
        store.save(s)
        #expect(store.take() == s)
        #expect(store.take() == nil)
    }

    @Test func roundTripsSuspension() throws {
        var session = Session(startedAt: t0, lidModeActive: false, lidModeEnabledAt: t0)
        session.lidModeSuspendedReason = .thermal
        let s = ResumeSnapshot(session: session, savedAt: t0)
        let decoded = try JSONDecoder().decode(ResumeSnapshot.self, from: JSONEncoder().encode(s))
        #expect(decoded == s)
        #expect(decoded.lidModeSuspendedReason == .thermal)
    }
}
