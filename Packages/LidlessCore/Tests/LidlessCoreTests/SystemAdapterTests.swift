import Testing
import Foundation
@testable import LidlessCore

@MainActor
struct SystemAdapterTests {
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
