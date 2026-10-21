import Foundation
import Testing
@testable import LidlessCore

@Suite struct LegacyHelperCleanerTests {
    private let pmset = ["/usr/bin/pmset", "-a", "disablesleep", "0"]
    private let bootout = ["/bin/launchctl", "bootout", "system/app.lidless.watchdog"]

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("legacy-cleaner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func touch(_ root: URL, _ path: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url)
    }

    private func exists(_ root: URL, _ path: String) -> Bool {
        var st = stat()
        return lstat(root.appendingPathComponent(path).path, &st) == 0
    }

    private let marker = "/Users/Shared/Lidless/lid-mode.marker"

    @Test func cleansFullInstall() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        for p in LegacyHelperCleaner.paths + [marker] { try touch(root, p) }
        let runner = FakeCommandRunner()
        let removed = try LegacyHelperCleaner(root: root, runner: runner).clean()
        // Contract: only files actually unlinked; the directory is removed but not reported.
        #expect(Set(removed) == Set(LegacyHelperCleaner.paths + [marker]))
        #expect(removed.count == 4)
        for p in LegacyHelperCleaner.paths + [marker, LegacyHelperCleaner.markerDirectory] {
            #expect(!exists(root, p))
        }
        #expect(runner.calls == [pmset, bootout])
    }

    @Test func noMarkerNoPmset() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try touch(root, LegacyHelperCleaner.paths[0])
        let runner = FakeCommandRunner()
        _ = try LegacyHelperCleaner(root: root, runner: runner).clean()
        #expect(runner.calls == [bootout])
    }

    @Test func partialInstall() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try touch(root, LegacyHelperCleaner.paths[1])
        let removed = try LegacyHelperCleaner(root: root, runner: FakeCommandRunner()).clean()
        #expect(removed == [LegacyHelperCleaner.paths[1]])
    }

    @Test func bootoutNotLoadedIsIgnored() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        for p in LegacyHelperCleaner.paths { try touch(root, p) }
        let runner = FakeCommandRunner()
        runner.setResponse(bootout.joined(separator: " "),
                           CommandResult(exitCode: 3, stdout: "", stderr: "not loaded"))
        let removed = try LegacyHelperCleaner(root: root, runner: runner).clean()
        #expect(removed.count == 3)
        for p in LegacyHelperCleaner.paths { #expect(!exists(root, p)) }
    }

    @Test func pmsetFailureThrowsAndDeletesNothing() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        for p in LegacyHelperCleaner.paths + [marker] { try touch(root, p) }
        let runner = FakeCommandRunner()
        runner.setResponse(pmset.joined(separator: " "),
                           CommandResult(exitCode: 1, stdout: "", stderr: "denied"))
        #expect(throws: HelperError.commandFailed("denied")) {
            try LegacyHelperCleaner(root: root, runner: runner).clean()
        }
        for p in LegacyHelperCleaner.paths + [marker] { #expect(exists(root, p)) }
    }

    @Test func symlinkedMarkerDirIsSkipped() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("elsewhere")
        try touch(root, "elsewhere/lid-mode.marker")
        let shared = root.appendingPathComponent("Users/Shared")
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: shared.appendingPathComponent("Lidless"), withDestinationURL: target)
        let runner = FakeCommandRunner()
        let removed = try LegacyHelperCleaner(root: root, runner: runner).clean()
        #expect(removed.isEmpty)
        #expect(!runner.calls.contains(pmset))
        #expect(exists(root, "elsewhere/lid-mode.marker"))
        #expect(exists(root, LegacyHelperCleaner.markerDirectory))
    }

    @Test func nonEmptyMarkerDirKept() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try touch(root, marker)
        try touch(root, "Users/Shared/Lidless/other.txt")
        let removed = try LegacyHelperCleaner(root: root, runner: FakeCommandRunner()).clean()
        #expect(removed == [marker])
        #expect(exists(root, "Users/Shared/Lidless/other.txt"))
        #expect(exists(root, LegacyHelperCleaner.markerDirectory))
    }

    @Test func isPresentMatchesAnyPath() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cleaner = LegacyHelperCleaner(root: root, runner: FakeCommandRunner())
        #expect(!cleaner.isPresent())
        try touch(root, LegacyHelperCleaner.paths[0])
        #expect(cleaner.isPresent())
    }

    private final class HookRunner: CommandRunner, @unchecked Sendable {
        let onRun: @Sendable (String) throws -> CommandResult
        init(_ onRun: @escaping @Sendable (String) throws -> CommandResult) { self.onRun = onRun }
        func run(_ executable: String, _ arguments: [String], timeout: TimeInterval?) throws -> CommandResult {
            try onRun(executable)
        }
    }

    private let ok = CommandResult(exitCode: 0, stdout: "", stderr: "")

    @Test func launchctlOtherExitCodeThrowsBeforeDeleting() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        for p in LegacyHelperCleaner.paths + [marker] { try touch(root, p) }
        let runner = FakeCommandRunner()
        runner.setResponse(bootout.joined(separator: " "), CommandResult(exitCode: 5, stdout: "", stderr: "boom"))
        #expect(throws: HelperError.self) { try LegacyHelperCleaner(root: root, runner: runner).clean() }
        for p in LegacyHelperCleaner.paths + [marker] { #expect(exists(root, p)) }
    }

    @Test func launchctlRunnerErrorThrowsBeforeDeleting() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        for p in LegacyHelperCleaner.paths { try touch(root, p) }
        let runner = HookRunner { _ in throw CommandError.timedOut("launchctl") }
        #expect(throws: HelperError.self) { try LegacyHelperCleaner(root: root, runner: runner).clean() }
        for p in LegacyHelperCleaner.paths { #expect(exists(root, p)) }
    }

    @Test func launchctl113IsOk() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try touch(root, LegacyHelperCleaner.paths[0])
        let runner = FakeCommandRunner()
        runner.setResponse(bootout.joined(separator: " "), CommandResult(exitCode: 113, stdout: "", stderr: ""))
        #expect(try LegacyHelperCleaner(root: root, runner: runner).clean().count == 1)
    }

    @Test func directorySwappedForSymlinkDuringCommandsIsHarmless() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try touch(root, marker)
        try touch(root, "elsewhere/lid-mode.marker")
        let dir = root.appendingPathComponent("Users/Shared/Lidless")
        let moved = root.appendingPathComponent("Users/Shared/Moved")
        let target = root.appendingPathComponent("elsewhere")
        let runner = HookRunner { exe in
            if exe == "/bin/launchctl" {
                try FileManager.default.moveItem(at: dir, to: moved)
                try FileManager.default.createSymbolicLink(at: dir, withDestinationURL: target)
            }
            return self.ok
        }
        _ = try LegacyHelperCleaner(root: root, runner: runner).clean()
        #expect(exists(root, "elsewhere/lid-mode.marker"))
        #expect(exists(root, LegacyHelperCleaner.markerDirectory))
    }

    @Test func symlinkAtLegacyPathIsUnlinkedTargetSurvives() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try touch(root, "real.txt")
        let p = LegacyHelperCleaner.paths[0]
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(p).deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent(p), withDestinationURL: root.appendingPathComponent("real.txt"))
        let removed = try LegacyHelperCleaner(root: root, runner: FakeCommandRunner()).clean()
        #expect(removed == [p])
        #expect(!exists(root, p))
        #expect(exists(root, "real.txt"))
    }

    @Test func danglingSymlinkIsPresentAndRemoved() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let p = LegacyHelperCleaner.paths[0]
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(p).deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent(p), withDestinationURL: root.appendingPathComponent("nowhere"))
        let cleaner = LegacyHelperCleaner(root: root, runner: FakeCommandRunner())
        #expect(cleaner.isPresent())
        #expect(try cleaner.clean() == [p])
        #expect(!cleaner.isPresent())
    }

    @Test func symlinkedMarkerFileIsUnlinkedTargetSurvives() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try touch(root, "real.txt")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(LegacyHelperCleaner.markerDirectory), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent(marker), withDestinationURL: root.appendingPathComponent("real.txt"))
        let removed = try LegacyHelperCleaner(root: root, runner: FakeCommandRunner()).clean()
        #expect(removed == [marker])
        #expect(exists(root, "real.txt"))
    }
}
