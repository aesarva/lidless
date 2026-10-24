import Testing
@testable import LidlessCore

@MainActor @Suite struct InstallGateTests {
    @Test func installWaitsForOpenLid() {
        let gate = InstallGate()
        var calls = 0
        #expect(!gate.ready(lidOpen: false) { calls += 1 })
        #expect(calls == 0)
        #expect(gate.lidOpened())
        #expect(calls == 1)
        #expect(!gate.lidOpened())
        #expect(calls == 1)
    }

    @Test func repeatedOpenWithoutPendingDoesNothing() {
        let gate = InstallGate()
        #expect(!gate.lidOpened())
        #expect(!gate.lidOpened())
    }

    @Test func openLidRepliesAtOnce() {
        let gate = InstallGate()
        var calls = 0
        #expect(gate.ready(lidOpen: true) { calls += 1 })
        #expect(calls == 1)
        #expect(!gate.lidOpened())
        #expect(calls == 1)
    }

    @Test func cancelForgetsReply() {
        let gate = InstallGate()
        var calls = 0
        gate.ready(lidOpen: false) { calls += 1 }
        gate.cancel()
        #expect(!gate.lidOpened())
        #expect(calls == 0)
    }
}
