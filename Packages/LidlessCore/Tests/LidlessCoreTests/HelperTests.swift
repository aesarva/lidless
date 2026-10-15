import Foundation
import Testing
@testable import LidlessCore

private func makeBackend(
    runner: FakeCommandRunner,
    helperDirectory: URL = URL(fileURLWithPath: "/tmp/helper"),
    fileExists: @escaping @Sendable (String) -> Bool = { _ in true }
) -> SudoersBackend {
    SudoersBackend(runner: runner, helperDirectory: helperDirectory, userName: "alex",
                   fileExists: fileExists)
}

@Suite struct HelperTests {
    @Test func parsesSleepDisabled() {
        #expect(PmsetParser.sleepDisabled(in: "Currently in use:\n SleepDisabled\t\t1\n") == true)
        #expect(PmsetParser.sleepDisabled(in: "SleepDisabled 0") == false)
        #expect(PmsetParser.sleepDisabled(in: "Currently in use:\n sleep 1\n") == false)
    }

    @Test func rendersExactRule() throws {
        let expected = """
        # Installed by Lidless. Remove via Lidless → Settings → Helper.
        alex ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1

        """
        #expect(try SudoersRule.render(userName: "alex") == expected)
    }

    @Test func renderedRulePassesVisudo() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("lidless-visudo-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        try SudoersRule.render(userName: NSUserName()).write(to: file, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/visudo")
        p.arguments = ["-cf", file.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        #expect(p.terminationStatus == 0)
    }

    @Test func rejectsUnsafeUserNames() throws {
        for bad in ["bad user", "a,b", "%admin", "ALL", "", "1abc", "x\ny"] {
            #expect(throws: HelperError.invalidUserName(bad)) { try SudoersRule.render(userName: bad) }
        }
        for good in ["alex", "a.b-c_d"] {
            #expect(throws: Never.self) { try SudoersRule.render(userName: good) }
        }
    }

    @Test func setSleepDisabledRunsSudoN() throws {
        let runner = FakeCommandRunner()
        let backend = makeBackend(runner: runner)
        try backend.setSleepDisabled(true)
        #expect(runner.calls == [["/usr/bin/sudo", "-n", "/usr/bin/pmset", "-a", "disablesleep", "1"]])

        runner.setResponse("/usr/bin/sudo -n /usr/bin/pmset -a disablesleep 0",
                           CommandResult(exitCode: 1, stdout: "", stderr: "a password is required"))
        #expect(throws: HelperError.commandFailed("a password is required")) {
            try backend.setSleepDisabled(false)
        }
    }

    @Test func isSleepDisabledReadsPmset() throws {
        let runner = FakeCommandRunner(responses: [
            "/usr/bin/pmset -g": CommandResult(exitCode: 0, stdout: " SleepDisabled\t\t1\n", stderr: "")
        ])
        #expect(try makeBackend(runner: runner).isSleepDisabled() == true)
    }

    @Test func statusMatrix() {
        let key = "/usr/bin/sudo -n -l /usr/bin/pmset -a disablesleep 1"
        let ok = FakeCommandRunner(responses: [key: CommandResult(exitCode: 0, stdout: "", stderr: "")])
        #expect(makeBackend(runner: ok, fileExists: { _ in true }).status() == .installed)

        let no = FakeCommandRunner(responses: [key: CommandResult(exitCode: 1, stdout: "", stderr: "")])
        #expect(makeBackend(runner: no, fileExists: { _ in true }).status() == .notInstalled)

        #expect(makeBackend(runner: ok, fileExists: { _ in false }).status() == .error("watchdog missing"))
    }

    @Test func installCommandEscapesPaths() throws {
        let dir = "/Users/o'brien/Down loads/Lidless \"2\".app/Contents/Resources/Helper"
        let backend = makeBackend(runner: FakeCommandRunner(), helperDirectory: URL(fileURLWithPath: dir))
        let rule = try SudoersRule.render(userName: "alex")
        let cmd = backend.installCommand(ruleText: rule)
        let q = "'/Users/o'\\''brien/Down loads/Lidless \"2\".app/Contents/Resources/Helper'"
        #expect(cmd == "/bin/bash '/Users/o'\\''brien/Down loads/Lidless \"2\".app/Contents/Resources/Helper/install.sh' '\(rule)' 'alex' \(q)")

        #expect(SudoersBackend.appleScriptString(#"a"b\c"#) == #""a\"b\\c""#)

        // Round-trip through a real shell: exactly 4 arguments, unchanged.
        let shellCmd = cmd.replacingOccurrences(of: "/bin/bash", with: "/usr/bin/printf '%s\\n'")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", shellCmd]
        let pipe = Pipe()
        p.standardOutput = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        #expect(p.terminationStatus == 0)
        // printf '%s\n' emits each argument followed by a newline.
        let expected = [dir + "/install.sh", rule, "alex", dir].map { $0 + "\n" }.joined()
        #expect(String(decoding: data, as: UTF8.self) == expected)
    }

    @Test func installCancelled() throws {
        let tmpDir = FileManager.default.temporaryDirectory.path
        let before = Set((try? FileManager.default.contentsOfDirectory(atPath: tmpDir)) ?? [])
        let runner = FakeCommandRunner()
        runner.fallback = CommandResult(exitCode: 1, stdout: "", stderr: "execution error: User canceled. (-128)")
        let helperDir = URL(fileURLWithPath: "/tmp/helper")
        let backend = makeBackend(runner: runner, helperDirectory: helperDir)
        #expect(throws: HelperError.cancelled) { try backend.install() }
        #expect(runner.calls.count == 1)
        #expect(runner.calls[0][0] == "/usr/bin/osascript")
        #expect(runner.calls[0][1] == "-e")
        let cmd = backend.installCommand(ruleText: try SudoersRule.render(userName: "alex"))
        #expect(runner.calls[0][2] == "do shell script " + SudoersBackend.appleScriptString(cmd) + " with administrator privileges")
        // The app must not write the rule anywhere.
        let after = Set((try? FileManager.default.contentsOfDirectory(atPath: tmpDir)) ?? [])
        #expect(after.filter { $0.hasPrefix("lidless-sudoers") && !before.contains($0) }.isEmpty)
    }

    @Test func installFailureAndUninstall() throws {
        let runner = FakeCommandRunner()
        runner.fallback = CommandResult(exitCode: 1, stdout: "", stderr: "boom")
        let backend = makeBackend(runner: runner)
        #expect(throws: HelperError.installFailed("boom")) { try backend.install() }
        #expect(throws: HelperError.installFailed("boom")) { try backend.uninstall() }

        let ok = FakeCommandRunner()
        try makeBackend(runner: ok).uninstall()
        let script = ok.calls[0][2]
        #expect(script.contains("/tmp/helper/uninstall.sh"))
        #expect(script.contains(SudoersBackend.markerPath))
    }
}
