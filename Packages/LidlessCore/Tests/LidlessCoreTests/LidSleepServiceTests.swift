import Testing
import Foundation
@testable import LidlessCore

@MainActor
struct LidSleepServiceTests {
    let backend = FakeBackend()
    let svc: LidSleepService

    init() {
        svc = LidSleepService(backend: backend)
    }

    @Test func enableThenDisable() throws {
        try svc.enable()
        #expect(backend.setCalls == [true])
        try svc.disable()
        #expect(backend.setCalls == [true, false])
        try svc.disable()
        #expect(backend.setCalls == [true, false])
    }

    @Test func disableWithoutEnableIsNoop() throws {
        try svc.disable()
        #expect(backend.setCalls == [])
    }

    @Test func enableFailureLeavesNothingToDisable() throws {
        backend.failNextSet = .commandFailed("x")
        #expect(throws: HelperError.commandFailed("x")) { try svc.enable() }
        try svc.disable()
        #expect(backend.setCalls == [true])
    }

    @Test func disableFailureKeepsEnabled() throws {
        try svc.enable()
        backend.failNextSet = .commandFailed("y")
        #expect(throws: HelperError.commandFailed("y")) { try svc.disable() }
        try svc.disable()
        #expect(backend.setCalls == [true, false, false])
    }

    /// The daemon let go when the connection dropped: nothing is left to turn off.
    @Test func connectionLostForgetsTheEnable() throws {
        try svc.enable()
        #expect(svc.connectionLost(generation: 1))
        try svc.disable()
        #expect(backend.setCalls == [true])
    }

    /// A late report about an older connection says nothing about a hold on a newer one.
    @Test func staleLossKeepsANewerHold() throws {
        try svc.enable()
        try svc.disable()
        backend.generation = 2
        try svc.enable()
        #expect(!svc.connectionLost(generation: 1))
        try svc.disable()
        #expect(backend.setCalls == [true, false, true, false])
    }

    @Test func newerLossEndsAnOlderHold() throws {
        try svc.enable()
        #expect(svc.connectionLost(generation: 2))
        try svc.disable()
        #expect(backend.setCalls == [true])
    }

    @Test func lossWithNothingHeldIsIgnored() {
        #expect(!svc.connectionLost(generation: 1))
    }

    @Test func recoverIsNoop() {
        #expect(svc.recoverIfNeeded())
        #expect(backend.setCalls == [])
    }
}
