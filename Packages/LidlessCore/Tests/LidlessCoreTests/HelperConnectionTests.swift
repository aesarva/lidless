import Foundation
import Testing
@testable import LidlessCore

/// Captures one `String?` reply.
private final class ReplyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String??
    let done = DispatchSemaphore(value: 0)

    func set(_ reply: String?) {
        lock.withLock { value = .some(reply) }
        done.signal()
    }

    var reply: String?? { lock.withLock { value } }
}

@Suite struct HelperConnectionTests {
    private let holder = UUID()

    private func make() -> (HelperConnection, SleepGuard, FakeSleepSetting) {
        let store = MemoryOwnershipStore()
        let setting = FakeSleepSetting(initial: false, store: store)
        let guardian = SleepGuard(setting: setting, store: store)
        let connection = HelperConnection(
            holder: holder, guard: guardian, cleaner: LegacyHelperCleaner(runner: FakeCommandRunner()),
            version: "1.0", build: "42", setting: setting
        )
        return (connection, guardian, setting)
    }

    /// The invalidation handler's sequence.
    private func invalidate(_ connection: HelperConnection, _ guardian: SleepGuard) {
        connection.markClosed()
        try? guardian.release(holder)
    }

    @Test func acquireAndReleaseReplyNil() {
        let (connection, guardian, setting) = make()
        let on = ReplyBox()
        connection.setSleepDisabled(true) { on.set($0) }
        #expect(on.reply == .some(nil))
        let off = ReplyBox()
        connection.setSleepDisabled(false) { off.set($0) }
        #expect(off.reply == .some(nil))
        #expect(setting.writes == [true, false])
        #expect(guardian.isIdle)
    }

    @Test func acquireAfterInvalidationIsRefused() {
        let (connection, guardian, setting) = make()
        invalidate(connection, guardian)
        let box = ReplyBox()
        connection.setSleepDisabled(true) { box.set($0) }
        #expect(box.reply == .some("connection closed"))
        #expect(setting.writes.isEmpty)
        #expect(guardian.isIdle)
    }

    @Test func invalidationDuringAcquireReleasesTheHolder() {
        let (connection, guardian, setting) = make()
        let block = setting.blockNextWrite()
        let box = ReplyBox()
        DispatchQueue.global().async { connection.setSleepDisabled(true) { box.set($0) } }
        block.started.wait()
        // The invalidation handler runs while the write 1 is in flight.
        let invalidated = DispatchSemaphore(value: 0)
        connection.markClosed()
        let id = holder
        DispatchQueue.global().async {
            try? guardian.release(id)
            invalidated.signal()
        }
        block.gate.signal()
        #expect(box.done.wait(timeout: .now() + 2) == .success)
        #expect(invalidated.wait(timeout: .now() + 2) == .success)
        #expect(box.reply == .some("connection closed"))
        #expect(setting.writes == [true, false])
        #expect(!setting.value)
        #expect(guardian.isIdle)
    }

    @Test func failedCompensatingReleaseLeavesAPendingReset() {
        let (connection, guardian, setting) = make()
        let block = setting.blockNextWrite()
        let box = ReplyBox()
        DispatchQueue.global().async { connection.setSleepDisabled(true) { box.set($0) } }
        block.started.wait()
        // Closed while acquiring; the handler's own release has not run yet.
        connection.markClosed()
        setting.failWriteZeroTimes = 1
        block.gate.signal()
        #expect(box.done.wait(timeout: .now() + 2) == .success)
        #expect(box.reply != .some(nil))
        #expect(setting.value)
        #expect(guardian.hasPendingReset)
        try? guardian.retryPendingReset()
        #expect(!setting.value)
        #expect(guardian.isIdle)
    }

    @Test func infoReadErrorIsReported() {
        let (connection, _, setting) = make()
        setting.failRead = true
        let result = ReplyBox()
        connection.info { version, _, _, _, error in
            #expect(version == "1.0")
            result.set(error)
        }
        #expect(result.reply != .some(nil))
    }

    @Test func infoRepliesBuildAndOwned() throws {
        let (connection, guardian, _) = make()
        let before = ReplyBox()
        connection.info { _, build, _, owned, _ in before.set("\(build) \(owned)") }
        #expect(before.reply == .some("42 false"))
        try guardian.acquire(holder)
        let after = ReplyBox()
        connection.info { _, build, _, owned, _ in after.set("\(build) \(owned)") }
        #expect(after.reply == .some("42 true"))
        #expect(guardian.ownsSetting)
    }

    @Test func cleanupRefusedWhileHeld() {
        let (connection, _, _) = make()
        connection.setSleepDisabled(true) { _ in }
        let result = ReplyBox()
        connection.removeLegacyHelper { removed, error in
            #expect(removed.isEmpty)
            result.set(error)
        }
        #expect(result.reply == .some("busy: closed-lid mode is active"))
    }
}
