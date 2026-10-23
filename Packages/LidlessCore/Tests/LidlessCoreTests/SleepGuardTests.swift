import Foundation
import Testing
@testable import LidlessCore

@Suite struct SleepGuardTests {
    private let a = UUID()
    private let b = UUID()

    private func make(initial: Bool, file: Bool = false)
        -> (SleepGuard, FakeSleepSetting, MemoryOwnershipStore) {
        let store = MemoryOwnershipStore(exists: file)
        let setting = FakeSleepSetting(initial: initial, store: store)
        return (SleepGuard(setting: setting, store: store), setting, store)
    }

    @Test func acquireFromZeroWritesFileThenOne() throws {
        let (guardian, setting, store) = make(initial: false)
        try guardian.acquire(a)
        #expect(store.exists())
        #expect(setting.writes == [true])
        #expect(setting.fileExistedAtWrite == [true])
    }

    @Test func releaseLastResetsAndRemovesFile() throws {
        let (guardian, setting, store) = make(initial: false)
        try guardian.acquire(a)
        try guardian.release(a)
        #expect(setting.writes == [true, false])
        #expect(setting.fileExistedAtWrite == [true, true])
        #expect(!store.exists())
        #expect(guardian.isIdle)
    }

    @Test func foreignOneIsLeftAlone() throws {
        let (guardian, setting, store) = make(initial: true)
        try guardian.acquire(a)
        try guardian.release(a)
        #expect(setting.writes.isEmpty)
        #expect(!store.exists())
    }

    @Test func ownOneFromEarlierIsAdopted() throws {
        let (guardian, setting, store) = make(initial: true, file: true)
        try guardian.acquire(a)
        try guardian.release(a)
        #expect(setting.writes == [false])
        #expect(!store.exists())
    }

    @Test func repeatedAcquireIsIdempotent() throws {
        let (guardian, setting, _) = make(initial: false)
        try guardian.acquire(a)
        try guardian.acquire(a)
        try guardian.release(a)
        #expect(setting.writes == [true, false])
    }

    @Test func twoHoldersResetOnlyAfterBoth() throws {
        let (guardian, setting, _) = make(initial: false)
        try guardian.acquire(a)
        try guardian.acquire(b)
        try guardian.release(a)
        #expect(setting.writes == [true])
        try guardian.release(b)
        #expect(setting.writes == [true, false])
    }

    @Test func releaseOfUnknownHolderIsNoop() throws {
        let (guardian, setting, store) = make(initial: false)
        try guardian.acquire(a)
        try guardian.release(b)
        #expect(setting.writes == [true])
        #expect(store.exists())
    }

    @Test func writeOneFailureRollsBack() throws {
        let (guardian, setting, store) = make(initial: false)
        setting.failWriteOne = true
        #expect(throws: FakeSleepSettingError.self) { try guardian.acquire(a) }
        #expect(setting.fileExistedAtAttempt.first == true)
        #expect(!store.exists())
        #expect(guardian.isIdle)
        #expect(setting.writes == [false])
    }

    @Test func writeOneFailureWithFailedRollbackKeepsFile() throws {
        let (guardian, setting, store) = make(initial: false)
        setting.failWriteOne = true
        setting.failWriteZeroTimes = 1
        #expect(throws: FakeSleepSettingError.self) { try guardian.acquire(a) }
        #expect(store.exists())
        #expect(!guardian.isIdle)
        try guardian.retryPendingReset()
        #expect(setting.writes.last == false)
        #expect(!store.exists())
        #expect(guardian.isIdle)
    }

    @Test func pendingResetOnlyWhileUnheld() throws {
        let (guardian, setting, _) = make(initial: false)
        try guardian.acquire(a)
        #expect(!guardian.hasPendingReset)
        setting.failWriteZeroTimes = 1
        #expect(throws: FakeSleepSettingError.self) { try guardian.release(a) }
        #expect(guardian.hasPendingReset)
        // A new holder takes the pending reset over: nothing to retry while it holds.
        try guardian.acquire(b)
        #expect(!guardian.hasPendingReset)
        try guardian.release(b)
        #expect(!guardian.hasPendingReset)
        #expect(guardian.isIdle)
    }

    @Test func performWhileUnheldRunsBody() throws {
        let (guardian, _, _) = make(initial: false)
        #expect(try guardian.performWhileUnheld { 42 } == 42)
    }

    @Test func performWhileUnheldRefusesWhileHeld() throws {
        let (guardian, _, _) = make(initial: false)
        try guardian.acquire(a)
        var ran = false
        #expect(throws: HelperError.commandFailed("busy: closed-lid mode is active")) {
            try guardian.performWhileUnheld { ran = true }
        }
        #expect(!ran)
    }

    @Test func acquireWaitsForPerformWhileUnheldBody() throws {
        let (guardian, setting, _) = make(initial: false)
        let entered = DispatchSemaphore(value: 0)
        let proceed = DispatchSemaphore(value: 0)
        let acquired = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            _ = try? guardian.performWhileUnheld {
                entered.signal()
                proceed.wait()
            }
        }
        entered.wait()
        let holder = a
        DispatchQueue.global().async {
            try? guardian.acquire(holder)
            acquired.signal()
        }
        #expect(acquired.wait(timeout: .now() + 0.2) == .timedOut)
        #expect(setting.fileExistedAtAttempt.isEmpty)
        proceed.signal()
        #expect(acquired.wait(timeout: .now() + 2) == .success)
        #expect(setting.writes == [true])
    }

    @Test func acquireAfterShutdownThrowsAndWritesNothing() throws {
        let (guardian, setting, store) = make(initial: false)
        try guardian.shutdown()
        #expect(throws: HelperError.commandFailed("shutting down")) { try guardian.acquire(a) }
        #expect(setting.fileExistedAtAttempt.isEmpty)
        #expect(!store.exists())
        #expect(throws: HelperError.commandFailed("shutting down")) {
            try guardian.performWhileUnheld {}
        }
    }

    @Test func shutdownReleasesAllHolders() throws {
        let (guardian, setting, store) = make(initial: false)
        try guardian.acquire(a)
        try guardian.acquire(b)
        try guardian.shutdown()
        #expect(setting.writes == [true, false])
        #expect(!store.exists())
        #expect(guardian.isIdle)
    }

    @Test func shutdownWithFailingResetStillCloses() throws {
        let (guardian, setting, store) = make(initial: false)
        try guardian.acquire(a)
        setting.failWriteZeroTimes = 1
        #expect(throws: FakeSleepSettingError.self) { try guardian.shutdown() }
        #expect(store.exists())
        #expect(throws: HelperError.commandFailed("shutting down")) { try guardian.acquire(b) }
        #expect(setting.writes == [true])
    }

    /// The SIGTERM handler retries a failed shutdown: the guard is already closed, but the
    /// retry still writes the 0.
    @Test func shutdownRetriedAfterAFailureResets() throws {
        let (guardian, setting, store) = make(initial: false)
        try guardian.acquire(a)
        setting.failWriteZeroTimes = 1
        #expect(throws: FakeSleepSettingError.self) { try guardian.shutdown() }
        try guardian.shutdown()
        #expect(setting.writes == [true, false])
        #expect(setting.value == false)
        #expect(!store.exists())
        #expect(guardian.isIdle)
    }

    /// The SIGTERM path: a failed reset is tried again.
    @Test func boundedShutdownRetriesAFailedReset() throws {
        let (guardian, setting, store) = make(initial: false)
        try guardian.acquire(a)
        setting.failWriteZeroTimes = 1
        #expect(guardian.shutdown(attempts: 3, pause: 0, within: 5))
        #expect(setting.writes == [true, false])
        #expect(!store.exists())
        #expect(throws: HelperError.commandFailed("shutting down")) { try guardian.acquire(b) }
    }

    @Test func boundedShutdownGivesUpAfterTheLastAttempt() throws {
        let (guardian, setting, store) = make(initial: false)
        try guardian.acquire(a)
        setting.failWriteZeroTimes = 10
        #expect(!guardian.shutdown(attempts: 3, pause: 0, within: 5))
        // The write 1, then three failed 0s.
        #expect(setting.fileExistedAtAttempt.count == 4)
        #expect(store.exists())
    }

    /// A hung pmset (or a wait for the lock behind one) cannot hold the exit past the
    /// budget, and no new attempt starts once it is spent.
    @Test func boundedShutdownReturnsWithinBudgetWhileAWriteHangs() throws {
        let (guardian, setting, store) = make(initial: false)
        try guardian.acquire(a)
        let block = setting.blockNextWrite()
        let started = Date()
        #expect(!guardian.shutdown(attempts: 3, pause: 0, within: 0.2))
        let elapsed = Date().timeIntervalSince(started)
        #expect(elapsed >= 0.2 && elapsed < 1)
        #expect(block.started.wait(timeout: .now()) == .success)
        // Let the abandoned attempt finish: it was the only one.
        block.gate.signal()
        for _ in 0..<100 where store.exists() { Thread.sleep(forTimeInterval: 0.01) }
        #expect(setting.fileExistedAtAttempt.count == 2)
        #expect(setting.writes == [true, false])
    }

    /// No pause is started that would end past the budget.
    @Test func boundedShutdownSkipsAPauseThatOverrunsTheBudget() throws {
        let (guardian, setting, _) = make(initial: false)
        try guardian.acquire(a)
        setting.failWriteZeroTimes = 10
        let started = Date()
        #expect(!guardian.shutdown(attempts: 3, pause: 5, within: 0.5))
        #expect(Date().timeIntervalSince(started) < 1)
        #expect(setting.fileExistedAtAttempt.count == 2)
    }

    @Test func shutdownIfIdleClosesOnlyWhenIdle() throws {
        let (guardian, setting, _) = make(initial: false)
        try guardian.acquire(a)
        #expect(!guardian.shutdownIfIdle())
        setting.failWriteZeroTimes = 1
        #expect(throws: FakeSleepSettingError.self) { try guardian.release(a) }
        #expect(!guardian.shutdownIfIdle())
        try guardian.retryPendingReset()
        #expect(guardian.shutdownIfIdle())
        #expect(throws: HelperError.commandFailed("shutting down")) { try guardian.acquire(b) }
        #expect(setting.writes == [true, false])
    }

    @Test func appliedWriteOneThenFailedRollbackStaysPending() throws {
        let (guardian, setting, store) = make(initial: false)
        setting.failWriteOne = true
        setting.applyFailedWriteOne = true
        setting.failWriteZeroTimes = 1
        #expect(throws: FakeSleepSettingError.self) { try guardian.acquire(a) }
        #expect(setting.value)
        #expect(store.exists())
        #expect(!guardian.isIdle)
        setting.failWriteOne = false
        try guardian.retryPendingReset()
        #expect(!setting.value)
        #expect(!store.exists())
        #expect(guardian.isIdle)
    }

    @Test func createFailureWithoutFileClaimsNothing() throws {
        let (guardian, setting, store) = make(initial: false)
        store.failCreate = true
        setting.failWriteOne = true
        setting.failWriteZeroTimes = 100
        #expect(throws: FakeSleepSettingError.self) { try guardian.acquire(a) }
        #expect(setting.writes.isEmpty)
        #expect(guardian.isIdle)
        setting.value = true
        try guardian.acquire(a)
        try guardian.release(a)
        #expect(setting.writes.isEmpty)
    }

    @Test func createFailureLeavingFileIsCleanedUp() throws {
        let (guardian, setting, store) = make(initial: false)
        store.failCreate = true
        store.failCreateLeavesFile = true
        #expect(throws: FakeSleepSettingError.self) { try guardian.acquire(a) }
        #expect(!store.exists())
        #expect(guardian.isIdle)
        #expect(setting.writes.isEmpty)
    }

    @Test func staleMarkerIsNotAdoptedAndIsRetried() throws {
        let (guardian, setting, store) = make(initial: false)
        store.failCreate = true
        store.failCreateLeavesFile = true
        store.failRemove = true
        #expect(throws: FakeSleepSettingError.self) { try guardian.acquire(a) }
        #expect(store.exists())
        #expect(!guardian.isIdle)
        #expect(setting.writes.isEmpty)
        setting.value = true
        try guardian.acquire(a)
        #expect(throws: FakeSleepSettingError.self) { try guardian.release(a) }
        #expect(setting.writes.isEmpty)
        #expect(store.exists())
        store.failRemove = false
        try guardian.retryPendingReset()
        #expect(!store.exists())
        #expect(guardian.isIdle)
        #expect(setting.writes.isEmpty)
    }

    @Test func staleMarkerIsRemovedOnRelease() throws {
        let (guardian, setting, store) = make(initial: false)
        store.failCreate = true
        store.failCreateLeavesFile = true
        store.failRemove = true
        #expect(throws: FakeSleepSettingError.self) { try guardian.acquire(a) }
        store.failRemove = false
        setting.value = true
        try guardian.acquire(a)
        try guardian.release(a)
        #expect(!store.exists())
        #expect(guardian.isIdle)
        #expect(setting.writes.isEmpty)
        #expect(setting.value)
    }

    @Test func staleMarkerIsRemovedOnReleaseAllSoTheNextDaemonLeavesForeignOneAlone() throws {
        let (guardian, setting, store) = make(initial: false)
        store.failCreate = true
        store.failCreateLeavesFile = true
        store.failRemove = true
        #expect(throws: FakeSleepSettingError.self) { try guardian.acquire(a) }
        store.failRemove = false
        try guardian.releaseAll()
        #expect(!store.exists())
        #expect(guardian.isIdle)
        #expect(setting.writes.isEmpty)
        setting.value = true
        let next = SleepGuard(setting: setting, store: store)
        try next.recoverAtStart()
        #expect(setting.writes.isEmpty)
        #expect(setting.value)
        #expect(next.isIdle)
    }

    @Test func staleMarkerIsClearedWhenALaterCreateFailureRemovesTheFile() throws {
        let (guardian, setting, store) = make(initial: false)
        store.failCreate = true
        store.failCreateLeavesFile = true
        store.failRemove = true
        #expect(throws: FakeSleepSettingError.self) { try guardian.acquire(a) }
        #expect(!guardian.isIdle)
        store.failRemove = false
        #expect(throws: FakeSleepSettingError.self) { try guardian.acquire(a) }
        #expect(!store.exists())
        #expect(guardian.isIdle)
        #expect(setting.writes.isEmpty)
    }

    @Test func removeFailureAfterResetStaysPending() throws {
        let (guardian, setting, store) = make(initial: false)
        try guardian.acquire(a)
        store.failRemove = true
        #expect(throws: FakeSleepSettingError.self) { try guardian.release(a) }
        #expect(!guardian.isIdle)
        store.failRemove = false
        try guardian.acquire(b)
        #expect(setting.writes.last == true)
        #expect(setting.value)
    }

    @Test func failedRecoverAtStartKeepsOwnership() throws {
        let (guardian, setting, store) = make(initial: true, file: true)
        setting.failWriteZeroTimes = 1
        #expect(throws: FakeSleepSettingError.self) { try guardian.recoverAtStart() }
        #expect(!guardian.isIdle)
        try guardian.releaseAll()
        #expect(!store.exists())
        #expect(guardian.isIdle)
    }

    @Test func staleFileWithFailedCleanupIsNotAdoptedAsForeign() throws {
        let (guardian, setting, store) = make(initial: false)
        setting.failWriteOne = true
        store.failRemove = true
        #expect(throws: FakeSleepSettingError.self) { try guardian.acquire(a) }
        #expect(!guardian.isIdle)
        store.failRemove = false
        setting.failWriteOne = false
        try guardian.retryPendingReset()
        #expect(!store.exists())
        #expect(guardian.isIdle)
        setting.value = true
        let before = setting.writes.count
        try guardian.acquire(a)
        try guardian.release(a)
        #expect(setting.writes.count == before)
    }

    @Test func retryPendingResetIsNoopWithHolders() throws {
        let (guardian, setting, store) = make(initial: false)
        try guardian.acquire(a)
        try guardian.retryPendingReset()
        #expect(setting.writes == [true])
        #expect(store.exists())
    }

    @Test func retryPendingResetIsNoopWhenIdle() throws {
        let (guardian, setting, _) = make(initial: true)
        try guardian.retryPendingReset()
        #expect(setting.writes.isEmpty)
        #expect(guardian.isIdle)
    }

    @Test func readFailureDuringAcquireLeavesNoFile() throws {
        let (guardian, setting, store) = make(initial: false)
        setting.failRead = true
        #expect(throws: FakeSleepSettingError.self) { try guardian.acquire(a) }
        #expect(!store.exists())
        #expect(setting.writes.isEmpty)
        #expect(guardian.isIdle)
    }

    @Test func writeZeroFailureKeepsFileAndRetries() throws {
        let (guardian, setting, store) = make(initial: false)
        try guardian.acquire(a)
        setting.failWriteZeroTimes = 1
        #expect(throws: FakeSleepSettingError.self) { try guardian.release(a) }
        #expect(store.exists())
        #expect(!guardian.isIdle)
        try guardian.releaseAll()
        #expect(setting.writes.last == false)
        #expect(!store.exists())
        #expect(guardian.isIdle)
    }

    @Test func recoverAtStartWithFileResets() throws {
        let (guardian, setting, store) = make(initial: true, file: true)
        try guardian.recoverAtStart()
        #expect(setting.writes == [false])
        #expect(!store.exists())
    }

    @Test func recoverAtStartWithZeroOnlyRemovesMarker() throws {
        let (guardian, setting, store) = make(initial: false, file: true)
        try guardian.recoverAtStart()
        #expect(setting.writes.isEmpty)
        #expect(!store.exists())
    }

    @Test func confirmedResetThenMarkerRemoveFailureDoesNotWriteAgain() throws {
        let (guardian, setting, store) = make(initial: false)
        try guardian.acquire(a)
        store.failRemove = true
        #expect(throws: FakeSleepSettingError.self) { try guardian.release(a) }
        #expect(setting.writes == [true, false])
        #expect(!guardian.ownsSetting)
        store.failRemove = false
        try guardian.retryPendingReset()
        #expect(setting.writes == [true, false])
        #expect(!store.exists())
        #expect(guardian.isIdle)
    }

    @Test func ownsSettingFollowsMarker() throws {
        let (guardian, _, _) = make(initial: false)
        #expect(!guardian.ownsSetting)
        try guardian.acquire(a)
        #expect(guardian.ownsSetting)
        try guardian.release(a)
        #expect(!guardian.ownsSetting)
    }

    @Test func recoverAtStartWithoutFileDoesNothing() throws {
        let (guardian, setting, _) = make(initial: true)
        try guardian.recoverAtStart()
        #expect(setting.writes.isEmpty)
    }

    @Test func releaseAllDropsEveryHolder() throws {
        let (guardian, setting, store) = make(initial: false)
        try guardian.acquire(a)
        try guardian.acquire(b)
        try guardian.releaseAll()
        #expect(setting.writes == [true, false])
        #expect(!store.exists())
        #expect(guardian.isIdle)
    }

    @Test func initDoesNotTouchSettingOrStore() {
        let (guardian, setting, store) = make(initial: true, file: true)
        #expect(setting.writes.isEmpty)
        #expect(store.exists())
        #expect(guardian.isIdle)
    }
}

@Suite struct PmsetSleepSettingTests {
    @Test func readsViaPmsetG() throws {
        let runner = FakeCommandRunner(responses: [
            "/usr/bin/pmset -g": CommandResult(exitCode: 0, stdout: " SleepDisabled\t\t1\n", stderr: "")
        ])
        #expect(try PmsetSleepSetting(runner: runner).isDisabled())
        #expect(runner.calls == [["/usr/bin/pmset", "-g"]])
    }

    @Test func writesDisablesleepOneAndZero() throws {
        let runner = FakeCommandRunner()
        let setting = PmsetSleepSetting(runner: runner)
        try setting.setDisabled(true)
        try setting.setDisabled(false)
        #expect(runner.calls == [
            ["/usr/bin/pmset", "-a", "disablesleep", "1"],
            ["/usr/bin/pmset", "-a", "disablesleep", "0"],
        ])
    }

    @Test func nonZeroExitOnWriteIsCommandFailed() {
        let runner = FakeCommandRunner()
        runner.fallback = CommandResult(exitCode: 1, stdout: "", stderr: "boom")
        #expect(throws: HelperError.commandFailed("boom")) {
            try PmsetSleepSetting(runner: runner).setDisabled(true)
        }
    }

    @Test func emptyStderrFallsBackToExitCode() {
        let runner = FakeCommandRunner()
        runner.fallback = CommandResult(exitCode: 1, stdout: "", stderr: "\n")
        #expect(throws: HelperError.commandFailed("pmset failed (exit 1)")) {
            try PmsetSleepSetting(runner: runner).setDisabled(false)
        }
    }

    @Test func helperErrorMessageIsTheTextAlone() {
        #expect(HelperError.message(for: HelperError.commandFailed("boom")) == "boom")
        #expect(HelperError.message(for: HelperError.installFailed("")) == "command failed")
        #expect(HelperError.message(for: FakeSleepSettingError()) == String(describing: FakeSleepSettingError()))
    }

    @Test func nonZeroExitOnReadIsCommandFailed() {
        let runner = FakeCommandRunner()
        runner.fallback = CommandResult(exitCode: 2, stdout: "", stderr: "nope")
        #expect(throws: HelperError.commandFailed("nope")) {
            try PmsetSleepSetting(runner: runner).isDisabled()
        }
    }
}

@Suite struct FileOwnershipStoreTests {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("lidless-test-\(UUID().uuidString)")
            .appendingPathComponent("Lidless/sleep-owned")
    }

    @Test func createsIntermediateDirectoryAndFile() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent().deletingLastPathComponent()) }
        let store = FileOwnershipStore(url: url)
        #expect(!store.exists())
        try store.create()
        #expect(store.exists())
        let fm = FileManager.default
        let dirPerm = try fm.attributesOfItem(atPath: url.deletingLastPathComponent().path)[.posixPermissions] as? Int
        let filePerm = try fm.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(dirPerm == 0o755)
        #expect(filePerm == 0o644)
    }

    @Test func removeDeletesAndMissingIsNotAnError() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent().deletingLastPathComponent()) }
        let store = FileOwnershipStore(url: url)
        try store.remove()
        try store.create()
        try store.remove()
        #expect(!store.exists())
        try store.remove()
    }
}
