import Testing
import Foundation
@testable import LidlessCore

@MainActor
struct LidSleepServiceTests {
    func makeService() -> (LidSleepService, FakeBackend, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lidless-test-\(UUID().uuidString)")
        let marker = dir.appendingPathComponent("sub/lid-mode.marker")
        let backend = FakeBackend()
        return (LidSleepService(backend: backend, markerURL: marker), backend, marker)
    }

    @Test func enableWritesMarkerThenDisables() throws {
        let (svc, backend, marker) = makeService()
        try svc.enable()
        #expect(FileManager.default.fileExists(atPath: marker.path))
        #expect(backend.setCalls == [true])
        try svc.disable()
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        #expect(backend.setCalls == [true, false])
    }

    @Test func enableFailureRemovesMarker() {
        let (svc, backend, marker) = makeService()
        backend.failNextSet = .commandFailed("x")
        #expect(throws: HelperError.commandFailed("x")) { try svc.enable() }
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func disableWithoutMarkerIsNoop() throws {
        let (svc, backend, _) = makeService()
        try svc.disable()
        #expect(backend.setCalls == [])
    }

    @Test func disableFailureKeepsMarker() throws {
        let (svc, backend, marker) = makeService()
        try svc.enable()
        backend.failNextSet = .commandFailed("y")
        #expect(throws: HelperError.commandFailed("y")) { try svc.disable() }
        #expect(FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func recoverResetsWhenMarkerPresent() throws {
        let (svc, backend, marker) = makeService()
        try FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("1".utf8).write(to: marker)
        #expect(svc.recoverIfNeeded())
        #expect(backend.setCalls == [false])
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func enableFailureKeepsPreexistingMarker() throws {
        let (svc, backend, marker) = makeService()
        try svc.enable()
        backend.failNextSet = .commandFailed("off")
        #expect(throws: HelperError.commandFailed("off")) { try svc.disable() }
        backend.failNextSet = .commandFailed("on")
        #expect(throws: HelperError.commandFailed("on")) { try svc.enable() }
        #expect(FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func recoverWithoutMarkerSucceeds() {
        let (svc, backend, _) = makeService()
        #expect(svc.recoverIfNeeded())
        #expect(backend.setCalls == [])
    }

    @Test func recoverReportsFailureAndKeepsMarker() throws {
        let (svc, backend, marker) = makeService()
        try svc.enable()
        backend.failNextSet = .commandFailed("z")
        #expect(!svc.recoverIfNeeded())
        #expect(FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func markerRemovedDuringDisableIsNotAFailure() throws {
        let (svc, backend, marker) = makeService()
        try svc.enable()
        backend.onSet = { try? FileManager.default.removeItem(at: marker) }
        try svc.disable()
        #expect(backend.setCalls == [true, false])
    }

    /// The watchdog (or an uninstall) may remove the marker while lid mode is on:
    /// what this process turned on it still turns off.
    @Test func disableResetsWhatItEnabledEvenWithoutMarker() throws {
        let (svc, backend, marker) = makeService()
        try svc.enable()
        try FileManager.default.removeItem(at: marker)
        try svc.disable()
        #expect(backend.setCalls == [true, false])
        try svc.disable()
        #expect(backend.setCalls == [true, false])
    }
}
