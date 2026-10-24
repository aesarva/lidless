import Foundation
import Testing
@testable import LidlessCore

@Suite struct UpdateStateTests {
    let notes = URL(string: "https://github.com/aesarva/lidless/releases/tag/v1.1")!

    func model(_ events: UpdateEvent...) -> UpdateModel {
        var model = UpdateModel()
        events.forEach { model.apply($0) }
        return model
    }

    @Test func backgroundCheckDoesNotShowChecking() {
        #expect(model(.checkStarted(userInitiated: false)).state == .idle)
    }

    @Test func manualCheckShowsChecking() {
        #expect(model(.checkStarted(userInitiated: true)).state == .checking)
    }

    @Test func foundShowsAvailable() {
        let m = model(.found(version: "1.1", notesURL: notes))
        #expect(m.state == .available(version: "1.1", notesURL: notes))
        #expect(m.showsBadge)
    }

    @Test func manualNotFoundIsUpToDate() {
        #expect(model(.checkStarted(userInitiated: true), .notFound(userInitiated: true)).state == .upToDate)
    }

    @Test func backgroundNotFoundIsIdle() {
        #expect(model(.checkStarted(userInitiated: false), .notFound(userInitiated: false)).state == .idle)
    }

    @Test func downloadProgress() {
        let m = model(.found(version: "1.1", notesURL: nil), .downloadStarted, .expectedLength(200),
                      .received(50), .received(50))
        #expect(m.state == .downloading(version: "1.1", progress: 0.5))
        #expect(m.showsBadge)
    }

    @Test func progressIsClamped() {
        let m = model(.found(version: "1.1", notesURL: nil), .downloadStarted, .expectedLength(100), .received(150))
        #expect(m.state == .downloading(version: "1.1", progress: 1.0))
    }

    @Test func unknownLengthHasNilProgress() {
        let m = model(.found(version: "1.1", notesURL: nil), .downloadStarted, .received(10))
        #expect(m.state == .downloading(version: "1.1", progress: nil))
    }

    @Test func installingKeepsVersion() {
        let m = model(.found(version: "1.1", notesURL: nil), .downloadStarted, .installing)
        #expect(m.state == .installing(version: "1.1"))
        #expect(m.showsBadge)
    }

    @Test func backgroundErrorIsSilent() {
        let m = model(.error(message: "x", userInitiated: false))
        #expect(m.state == .idle)
        #expect(!m.showsBadge)
    }

    @Test func manualErrorFails() {
        let m = model(.checkStarted(userInitiated: true), .error(message: "x", userInitiated: true))
        #expect(m.state == .failed(message: "x"))
        #expect(!m.showsBadge)
    }

    @Test func downloadErrorFails() {
        let m = model(.found(version: "1.1", notesURL: nil), .downloadStarted, .error(message: "x", userInitiated: false))
        #expect(m.state == .failed(message: "x"))
    }

    @Test func dismissKeepsAvailableAndFailed() {
        #expect(model(.found(version: "1.1", notesURL: nil), .dismissed).state == .available(version: "1.1", notesURL: nil))
        #expect(model(.checkStarted(userInitiated: true), .error(message: "x", userInitiated: true), .dismissed).state
            == .failed(message: "x"))
    }

    @Test func dismissClearsInProgress() {
        #expect(model(.found(version: "1.1", notesURL: nil), .downloadStarted, .dismissed).state == .idle)
    }

    @Test func newDownloadResetsCounters() {
        let m = model(.found(version: "1.1", notesURL: nil), .downloadStarted, .expectedLength(100), .received(100),
                      .found(version: "1.2", notesURL: nil), .downloadStarted, .received(10))
        #expect(m.state == .downloading(version: "1.2", progress: nil))
    }

    @Test func unsupportedLocationAsksToMove() {
        let m = model(.checkStarted(userInitiated: false), .locationUnsupported)
        #expect(m.state == .needsMove)
        #expect(!m.showsBadge)
    }

    @Test func dismissKeepsNeedsMove() {
        #expect(model(.locationUnsupported, .dismissed).state == .needsMove)
    }

    @Test func updatableLocations() {
        #expect(UpdateLocation.canUpdate(bundlePath: "/Applications/Lidless.app", volumeIsReadOnly: false))
        #expect(!UpdateLocation.canUpdate(bundlePath: "/Volumes/Lidless 1.1.0/Lidless.app", volumeIsReadOnly: true))
        #expect(!UpdateLocation.canUpdate(
            bundlePath: "/private/var/folders/x/AppTranslocation/1A2B/d/Lidless.app", volumeIsReadOnly: false))
    }

    @Test func backgroundSuccessClearsStaleResults() {
        #expect(model(.checkStarted(userInitiated: true), .error(message: "x", userInitiated: true),
                      .backgroundCheckSucceeded).state == .idle)
        #expect(model(.checkStarted(userInitiated: true), .notFound(userInitiated: true),
                      .backgroundCheckSucceeded).state == .idle)
    }

    @Test func backgroundSuccessKeepsOfferAndHint() {
        #expect(model(.found(version: "1.1", notesURL: nil), .backgroundCheckSucceeded).state
            == .available(version: "1.1", notesURL: nil))
        #expect(model(.locationUnsupported, .backgroundCheckSucceeded).state == .needsMove)
    }

    @Test func progressMovesInWholePercents() {
        let m = model(.found(version: "1.1", notesURL: nil), .downloadStarted, .expectedLength(300), .received(100))
        #expect(m.state == .downloading(version: "1.1", progress: 0.33))
    }

    @Test func expiredOfferClearsBadge() {
        let m = model(.found(version: "1.1", notesURL: nil), .offerExpired)
        #expect(m.state == .idle)
        #expect(!m.showsBadge)
    }

    @Test func offerExpiryLeavesOtherStates() {
        #expect(model(.found(version: "1.1", notesURL: nil), .downloadStarted, .offerExpired).state
            == .downloading(version: "1.1", progress: nil))
        #expect(model(.locationUnsupported, .offerExpired).state == .needsMove)
    }

    @Test func waitingForLidShowsBadge() {
        let m = model(.found(version: "1.1", notesURL: nil), .downloadStarted, .installing, .waitingForOpenLid)
        #expect(m.state == .waitingForLid(version: "1.1"))
        #expect(m.showsBadge)
    }

    @Test func dismissedFromWaitingIsIdle() {
        #expect(model(.found(version: "1.1", notesURL: nil), .downloadStarted, .installing, .waitingForOpenLid,
                      .dismissed).state == .idle)
    }

    @Test func waitingThenInstallingKeepsVersion() {
        let m = model(.found(version: "1.1", notesURL: nil), .downloadStarted, .installing, .waitingForOpenLid,
                      .installing)
        #expect(m.state == .installing(version: "1.1"))
    }

    @Test func errorWhileWaitingFails() {
        let m = model(.found(version: "1.1", notesURL: nil), .downloadStarted, .installing, .waitingForOpenLid,
                      .error(message: "x", userInitiated: false))
        #expect(m.state == .failed(message: "x"))
    }
}
