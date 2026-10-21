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
        // Contract: the three files, the marker and the marker directory (when removed).
        #expect(Set(removed) == Set(LegacyHelperCleaner.paths + [marker, LegacyHelperCleaner.markerDirectory]))
        #expect(removed.count == 5)
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
}
