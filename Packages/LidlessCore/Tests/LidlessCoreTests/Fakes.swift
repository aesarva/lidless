import Foundation
@testable import LidlessCore

/// Records every call and answers from a table keyed by "exe arg1 arg2".
/// Unknown commands get `fallback` (exit 0, empty output).
final class FakeCommandRunner: CommandRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var _responses: [String: CommandResult]
    private var _calls: [[String]] = []
    private var _fallback = CommandResult(exitCode: 0, stdout: "", stderr: "")

    init(responses: [String: CommandResult] = [:]) { _responses = responses }

    var calls: [[String]] { lock.lock(); defer { lock.unlock() }; return _calls }

    var fallback: CommandResult {
        get { lock.lock(); defer { lock.unlock() }; return _fallback }
        set { lock.lock(); defer { lock.unlock() }; _fallback = newValue }
    }

    func setResponse(_ key: String, _ result: CommandResult) {
        lock.lock(); defer { lock.unlock() }
        _responses[key] = result
    }

    private var _timeouts: [TimeInterval?] = []
    var timeouts: [TimeInterval?] { lock.lock(); defer { lock.unlock() }; return _timeouts }

    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval?) throws -> CommandResult {
        lock.lock(); defer { lock.unlock() }
        _calls.append([executable] + arguments)
        _timeouts.append(timeout)
        return _responses[([executable] + arguments).joined(separator: " ")] ?? _fallback
    }
}

final class FakeBackend: PrivilegedBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var _status: HelperStatus = .installed
    private var _failNextSet: HelperError?
    private var _setCalls: [Bool] = []

    var stubStatus: HelperStatus {
        get { lock.lock(); defer { lock.unlock() }; return _status }
        set { lock.lock(); defer { lock.unlock() }; _status = newValue }
    }
    var failNextSet: HelperError? {
        get { lock.lock(); defer { lock.unlock() }; return _failNextSet }
        set { lock.lock(); defer { lock.unlock() }; _failNextSet = newValue }
    }
    var setCalls: [Bool] { lock.lock(); defer { lock.unlock() }; return _setCalls }
    /// Runs after each recorded set, outside the lock (e.g. to race the marker).
    nonisolated(unsafe) var onSet: (() -> Void)?

    func status() -> HelperStatus { stubStatus }
    func install() throws {}
    func uninstall() throws {}
    func setSleepDisabled(_ disabled: Bool) throws {
        lock.lock()
        _setCalls.append(disabled)
        let failure = _failNextSet
        _failNextSet = nil
        lock.unlock()
        onSet?()
        if let failure { throw failure }
    }
    func isSleepDisabled() throws -> Bool { lock.lock(); defer { lock.unlock() }; return _setCalls.last ?? false }
}

// MARK: - Session controller fakes

final class MutableClock: WakeClock, @unchecked Sendable {
    private let lock = NSLock()
    private var _now: Date
    init(_ start: Date) { _now = start }
    var now: Date { lock.lock(); defer { lock.unlock() }; return _now }
    func advance(_ seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        _now = _now.addingTimeInterval(seconds)
    }
}

struct FakeError: Error {}

@MainActor final class FakeAssertions: SleepAssertionService {
    var acquired: [Bool] = []
    var released = 0
    var failNext = false
    func acquire(keepDisplayOn: Bool) throws {
        if failNext { failNext = false; throw FakeError() }
        acquired.append(keepDisplayOn)
    }
    func release() { released += 1 }
}

@MainActor final class FakeNotifier: Notifier {
    var posted: [WakeNotification] = []
    var cancelEndingSoonCount = 0
    func post(_ n: WakeNotification) { posted.append(n) }
    func cancelEndingSoon() { cancelEndingSoonCount += 1 }
}

@MainActor final class FakeLid: LidSleepControlling {
    var enableCalls = 0
    var disableCalls = 0
    var recoverCalls = 0
    var failEnable = false
    var failDisable = false
    var failRecover = false
    var status: HelperStatus = .installed
    func helperStatus() -> HelperStatus { status }
    func enable() throws {
        enableCalls += 1
        if failEnable { throw FakeError() }
    }
    func disable() throws {
        disableCalls += 1
        if failDisable { throw FakeError() }
    }
    func recoverIfNeeded() -> Bool {
        recoverCalls += 1
        return !failRecover
    }
}

@MainActor final class FakePower: PowerMonitoring {
    var reading = PowerReading(batteryLevel: 80, onBattery: false)
    var onChange: (() -> Void)?
    func current() -> PowerReading { reading }
}

@MainActor final class FakeThermal: ThermalMonitoring {
    var level: ThermalLevel = .nominal
    var onChange: (() -> Void)?
    func current() -> ThermalLevel { level }
}

@MainActor final class FakeLidMonitor: LidMonitoring {
    var closed = false
    var onChange: (() -> Void)?
    func isLidClosed() -> Bool { closed }
}

@MainActor final class MemorySettingsStore: SettingsStore {
    var stored: LidlessSettings
    var saveCount = 0
    init(_ initial: LidlessSettings = LidlessSettings()) { stored = initial }
    func load() -> LidlessSettings { stored }
    func save(_ s: LidlessSettings) { stored = s; saveCount += 1 }
}

@MainActor final class FakeDisplay: DisplayControlling {
    var external = false
    var sleepCalls = 0
    func hasExternalDisplay() -> Bool { external }
    func sleepDisplayNow() { sleepCalls += 1 }
}
