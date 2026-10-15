import Testing
import Foundation
@testable import WakeUpCore

@MainActor
struct LidSleepServiceTests {
    func makeService() -> (LidSleepService, FakeBackend, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wakeup-test-\(UUID().uuidString)")
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
        svc.recoverIfNeeded()
        #expect(backend.setCalls == [false])
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }
}
