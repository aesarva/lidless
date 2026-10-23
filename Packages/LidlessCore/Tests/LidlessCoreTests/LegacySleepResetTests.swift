import Foundation
import Testing
@testable import LidlessCore

@Suite struct LegacySleepResetTests {
    private let sudoPmset = ["/usr/bin/sudo", "-n", "/usr/bin/pmset", "-a", "disablesleep", "0"]
    private let marker = "/Users/Shared/Lidless/lid-mode.marker"
    private let rule = "/etc/sudoers.d/lidless"

    /// A temporary root holding the given 0.2.0 files.
    private func makeRoot(_ paths: [String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("legacy-reset-\(UUID().uuidString)")
        for path in paths {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
        }
        return root
    }

    private func exists(_ root: URL, _ path: String) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path)
    }

    @Test func leftoverWithoutDaemonIsReset() throws {
        let root = try makeRoot([marker, rule])
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = FakeCommandRunner()
        LegacySleepReset(root: root, runner: runner)
            .resetIfNeeded(helperStatus: .needsApproval, otherCopyRunning: false)
        #expect(runner.calls == [sudoPmset])
        #expect(!exists(root, marker))
        #expect(exists(root, rule))
    }

    /// Without a daemon the app may be unsigned or the daemon never set up: both reset too.
    @Test func everyStatusButInstalledResets() throws {
        for status: HelperStatus in [.notInstalled, .unsigned, .error("timed out")] {
            let root = try makeRoot([marker, rule])
            defer { try? FileManager.default.removeItem(at: root) }
            let runner = FakeCommandRunner()
            LegacySleepReset(root: root, runner: runner).resetIfNeeded(helperStatus: status, otherCopyRunning: false)
            #expect(runner.calls == [sudoPmset])
        }
    }

    /// A 1 without the 0.2.0 marker is someone else's: never reset.
    @Test func noMarkerDoesNothing() throws {
        let root = try makeRoot([rule])
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = FakeCommandRunner()
        LegacySleepReset(root: root, runner: runner)
            .resetIfNeeded(helperStatus: .notInstalled, otherCopyRunning: false)
        #expect(runner.calls.isEmpty)
    }

    /// Without the 0.2.0 sudoers rule `sudo -n` cannot run pmset.
    @Test func noRuleDoesNothing() throws {
        let root = try makeRoot([marker])
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = FakeCommandRunner()
        LegacySleepReset(root: root, runner: runner)
            .resetIfNeeded(helperStatus: .notInstalled, otherCopyRunning: false)
        #expect(runner.calls.isEmpty)
        #expect(exists(root, marker))
    }

    /// The daemon's own 0.2.0 cleanup resets it when it starts.
    @Test func installedDaemonIsLeftToCleanUp() throws {
        let root = try makeRoot([marker, rule])
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = FakeCommandRunner()
        LegacySleepReset(root: root, runner: runner)
            .resetIfNeeded(helperStatus: .installed, otherCopyRunning: false)
        #expect(runner.calls.isEmpty)
        #expect(exists(root, marker))
    }

    /// A running 0.2.0 copy owns its session.
    @Test func anotherCopyRunningDoesNothing() throws {
        let root = try makeRoot([marker, rule])
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = FakeCommandRunner()
        LegacySleepReset(root: root, runner: runner)
            .resetIfNeeded(helperStatus: .notInstalled, otherCopyRunning: true)
        #expect(runner.calls.isEmpty)
        #expect(exists(root, marker))
    }

    @Test func failedResetKeepsMarker() throws {
        let root = try makeRoot([marker, rule])
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = FakeCommandRunner()
        runner.fallback = CommandResult(exitCode: 1, stdout: "", stderr: "sudo: a password is required")
        LegacySleepReset(root: root, runner: runner)
            .resetIfNeeded(helperStatus: .notInstalled, otherCopyRunning: false)
        #expect(runner.calls == [sudoPmset])
        #expect(exists(root, marker))
    }

    @Test func runnerErrorKeepsMarker() throws {
        let root = try makeRoot([marker, rule])
        defer { try? FileManager.default.removeItem(at: root) }
        LegacySleepReset(root: root, runner: ThrowingRunner())
            .resetIfNeeded(helperStatus: .notInstalled, otherCopyRunning: false)
        #expect(exists(root, marker))
    }
}

private struct ThrowingRunner: CommandRunner {
    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval?) throws -> CommandResult {
        throw HelperError.commandFailed("timed out")
    }
}
