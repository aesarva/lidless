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

    @Test func writeOneFailureRemovesFile() throws {
        let (guardian, setting, store) = make(initial: false)
        setting.failWriteOne = true
        #expect(throws: FakeSleepSettingError.self) { try guardian.acquire(a) }
        #expect(!store.exists())
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

    @Test func recoverAtStartWithoutFileDoesNothing() throws {
        let (guardian, setting, _) = make(initial: true)
        try guardian.recoverAtStart()
        #expect(setting.writes.isEmpty)
    }

    @Test func releaseAllDropsEveryHolder() throws {
        let (guardian, setting, _) = make(initial: false)
        try guardian.acquire(a)
        try guardian.acquire(b)
        try guardian.releaseAll()
        #expect(setting.writes == [true, false])
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
