import Testing
import Foundation
@testable import LidlessCore

@MainActor
struct SystemAdapterTests {
    @Test func parsesSleepDisabled() {
        #expect(PmsetParser.sleepDisabled(in: "Currently in use:\n SleepDisabled\t\t1\n") == true)
        #expect(PmsetParser.sleepDisabled(in: "SleepDisabled 0") == false)
        #expect(PmsetParser.sleepDisabled(in: "Currently in use:\n sleep 1\n") == false)
    }

    @Test func settingsStoreRoundTripAndCorruption() throws {
        let suite = "lidless.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsSettingsStore(defaults: defaults)
        var s = LidlessSettings()
        s.keepDisplayOn = true
        s.presetMinutes = [5, 10]
        store.save(s)
        #expect(store.load() == s)
        defaults.set(Data("x".utf8), forKey: "settings.v1")
        #expect(store.load() == LidlessSettings())
    }

    @Test func assertionAppearsInPmset() throws {
        let service = IOPMSleepAssertionService()
        defer { service.release() }
        let runner = ProcessCommandRunner()
        try service.acquire(keepDisplayOn: true)
        // Only this test process's assertions count: a running Lidless app holds its own.
        let mine = "pid \(ProcessInfo.processInfo.processIdentifier)("
        func ours(_ out: String) -> Bool {
            out.split(separator: "\n").contains { $0.contains(mine) && $0.contains("Lidless session") }
        }
        let during = try runner.run("/usr/bin/pmset", ["-g", "assertions"])
        #expect(ours(during.stdout))
        service.release()
        let after = try runner.run("/usr/bin/pmset", ["-g", "assertions"])
        #expect(!ours(after.stdout))
    }

    /// waitUntilExit() would spin the main run loop: timers and main-queue work would then
    /// run in the middle of a SessionController state change.
    @Test func runnerDoesNotSpinTheRunLoop() throws {
        final class Count: @unchecked Sendable { var value = 0 }
        let fired = Count()
        let timer = Timer(timeInterval: 0.02, repeats: true) { _ in fired.value += 1 }
        RunLoop.main.add(timer, forMode: .common)
        defer { timer.invalidate() }
        let r = try ProcessCommandRunner().run("/bin/sleep", ["0.3"])
        #expect(r.exitCode == 0)
        #expect(fired.value == 0)
    }

    @Test func runnerKillsACommandPastItsTimeout() {
        let started = Date()
        #expect(throws: CommandError.timedOut("/bin/sleep 10")) {
            try ProcessCommandRunner().run("/bin/sleep", ["10"], timeout: 0.2)
        }
        #expect(Date().timeIntervalSince(started) < 3)
    }

    @Test func runnerCapturesOutput() throws {
        let r = try ProcessCommandRunner().run("/bin/sh", ["-c", "echo out; echo err >&2; exit 3"])
        #expect(r == CommandResult(exitCode: 3, stdout: "out\n", stderr: "err\n"))
    }

    @Test func powerReadingIsSane() {
        let monitor = IOPowerMonitor()
        if let level = monitor.current().batteryLevel { #expect((0...100).contains(level)) }
    }

    @Test func thermalMonitorReturnsLevel() {
        let m = SystemThermalMonitor()
        #expect(ThermalLevel.nominal <= m.current())
    }

    @Test func lidMonitorDoesNotCrash() {
        #expect(IORegistryLidMonitor().isLidClosed() == false)
    }
}
