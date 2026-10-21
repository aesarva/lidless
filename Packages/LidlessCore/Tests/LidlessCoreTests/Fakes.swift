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

    func status() -> HelperStatus { stubStatus }
    func refreshInfo() {}
    func install() throws {}
    func uninstall() throws {}
    func legacyHelperPresent() -> Bool { false }
    func removeLegacyHelper() throws -> [String] { [] }
    func openSystemSettings() {}
    func setSleepDisabled(_ disabled: Bool) throws {
        lock.lock()
        _setCalls.append(disabled)
        let failure = _failNextSet
        _failNextSet = nil
        lock.unlock()
        if let failure { throw failure }
    }
    func isSleepDisabled() throws -> Bool { lock.lock(); defer { lock.unlock() }; return _setCalls.last ?? false }
}

final class FakeRegistration: HelperRegistration, @unchecked Sendable {
    private let lock = NSLock()
    private var _status: RegistrationStatus
    private var _registerCalls = 0
    private var _unregisterCalls = 0
    private var _openSettingsCalls = 0
    private var _registerError: Error?
    private var _statusAfterRegister: RegistrationStatus?
    private var _onRegister: (@Sendable () -> Void)?

    init(status: RegistrationStatus = .notRegistered) { _status = status }

    /// Runs at the start of each `register()`, outside the lock (e.g. to pause it).
    var onRegister: (@Sendable () -> Void)? {
        get { lock.withLock { _onRegister } }
        set { lock.withLock { _onRegister = newValue } }
    }

    var stubStatus: RegistrationStatus {
        get { lock.withLock { _status } }
        set { lock.withLock { _status = newValue } }
    }
    /// Thrown by every `register()`; the status stays as it was.
    var registerError: Error? {
        get { lock.withLock { _registerError } }
        set { lock.withLock { _registerError = newValue } }
    }
    /// The status a successful `register()` leaves (default: `.enabled`).
    var statusAfterRegister: RegistrationStatus? {
        get { lock.withLock { _statusAfterRegister } }
        set { lock.withLock { _statusAfterRegister = newValue } }
    }
    var registerCalls: Int { lock.withLock { _registerCalls } }
    var unregisterCalls: Int { lock.withLock { _unregisterCalls } }
    var openSettingsCalls: Int { lock.withLock { _openSettingsCalls } }

    var status: RegistrationStatus { stubStatus }

    func register() throws {
        onRegister?()
        lock.lock(); defer { lock.unlock() }
        _registerCalls += 1
        if let _registerError { throw _registerError }
        _status = _statusAfterRegister ?? .enabled
    }

    func unregister() throws {
        lock.withLock {
            _unregisterCalls += 1
            _status = .notRegistered
        }
    }

    func openSystemSettings() { lock.withLock { _openSettingsCalls += 1 } }
}

final class FakeHelperClient: HelperClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _info = HelperInfo(version: "0.3.0", sleepDisabled: false)
    private var _infoError: Error?
    private var _setError: Error?
    private var _setCalls: [Bool] = []
    private var _infoCalls = 0
    private var _removeLegacyResult: Result<[String], HelperError> = .success([])
    private var _lostHandler: (@Sendable () -> Void)?
    private var _infoScript: [Result<HelperInfo, HelperError>] = []
    private var _onInfo: (@Sendable () -> Void)?

    /// Answers for the next `info()` calls, in order; then `stubInfo` / `infoError` again.
    var infoScript: [Result<HelperInfo, HelperError>] {
        get { lock.withLock { _infoScript } }
        set { lock.withLock { _infoScript = newValue } }
    }
    /// Runs at the start of each `info()`, outside the lock.
    var onInfo: (@Sendable () -> Void)? {
        get { lock.withLock { _onInfo } }
        set { lock.withLock { _onInfo = newValue } }
    }

    var stubInfo: HelperInfo {
        get { lock.withLock { _info } }
        set { lock.withLock { _info = newValue } }
    }
    var infoError: Error? {
        get { lock.withLock { _infoError } }
        set { lock.withLock { _infoError = newValue } }
    }
    var setError: Error? {
        get { lock.withLock { _setError } }
        set { lock.withLock { _setError = newValue } }
    }
    var removeLegacyResult: Result<[String], HelperError> {
        get { lock.withLock { _removeLegacyResult } }
        set { lock.withLock { _removeLegacyResult = newValue } }
    }
    var setCalls: [Bool] { lock.withLock { _setCalls } }
    var infoCalls: Int { lock.withLock { _infoCalls } }

    var onConnectionLost: (@Sendable () -> Void)? {
        get { lock.withLock { _lostHandler } }
        set { lock.withLock { _lostHandler = newValue } }
    }

    func setSleepDisabled(_ disabled: Bool) throws {
        lock.lock(); defer { lock.unlock() }
        _setCalls.append(disabled)
        if let _setError { throw _setError }
    }

    func info() throws -> HelperInfo {
        onInfo?()
        lock.lock(); defer { lock.unlock() }
        _infoCalls += 1
        if !_infoScript.isEmpty { return try _infoScript.removeFirst().get() }
        if let _infoError { throw _infoError }
        return _info
    }

    func removeLegacyHelper() throws -> [String] {
        lock.lock(); defer { lock.unlock() }
        return try _removeLegacyResult.get()
    }
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
    var connectionLostCalls = 0
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
    func connectionLost() { connectionLostCalls += 1 }
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

final class MemoryOwnershipStore: OwnershipStore, @unchecked Sendable {
    private let lock = NSLock()
    private var _exists: Bool
    init(exists: Bool = false) { _exists = exists }

    func exists() -> Bool { lock.lock(); defer { lock.unlock() }; return _exists }
    private var _failRemove = false
    private var _failCreate = false
    private var _failCreateLeavesFile = false
    var failRemove: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _failRemove }
        set { lock.lock(); defer { lock.unlock() }; _failRemove = newValue }
    }
    /// With `failCreate`: the file is written before create() throws.
    var failCreateLeavesFile: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _failCreateLeavesFile }
        set { lock.lock(); defer { lock.unlock() }; _failCreateLeavesFile = newValue }
    }
    var failCreate: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _failCreate }
        set { lock.lock(); defer { lock.unlock() }; _failCreate = newValue }
    }

    func create() throws {
        lock.lock(); defer { lock.unlock() }
        if _failCreate {
            if _failCreateLeavesFile { _exists = true }
            throw FakeSleepSettingError()
        }
        _exists = true
    }
    func remove() throws {
        lock.lock(); defer { lock.unlock() }
        if _failRemove { throw FakeSleepSettingError() }
        _exists = false
    }
}

struct FakeSleepSettingError: Error, Equatable {}

/// Records successful writes and, for each, whether the ownership file existed at that moment.
final class FakeSleepSetting: SleepSetting, @unchecked Sendable {
    private let lock = NSLock()
    private let store: MemoryOwnershipStore
    private var _value: Bool
    private var _writes: [Bool] = []
    private var _fileExistedAtWrite: [Bool] = []
    private var _fileExistedAtAttempt: [Bool] = []
    private var _failRead = false
    private var _failWriteOne = false
    private var _applyFailedWriteOne = false
    private var _failWriteZeroTimes = 0
    private var _block: (started: DispatchSemaphore, gate: DispatchSemaphore)?

    init(initial: Bool, store: MemoryOwnershipStore) { _value = initial; self.store = store }

    /// The next write signals `started`, then waits for `gate` (a slow pmset). The caller
    /// (SleepGuard) holds its own lock all the while.
    func blockNextWrite() -> (started: DispatchSemaphore, gate: DispatchSemaphore) {
        let block = (started: DispatchSemaphore(value: 0), gate: DispatchSemaphore(value: 0))
        lock.lock(); defer { lock.unlock() }
        _block = block
        return block
    }

    var fileExistedAtAttempt: [Bool] { lock.lock(); defer { lock.unlock() }; return _fileExistedAtAttempt }
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); defer { lock.unlock() }; _value = newValue }
    }
    var writes: [Bool] { lock.lock(); defer { lock.unlock() }; return _writes }
    var fileExistedAtWrite: [Bool] { lock.lock(); defer { lock.unlock() }; return _fileExistedAtWrite }
    var failRead: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _failRead }
        set { lock.lock(); defer { lock.unlock() }; _failRead = newValue }
    }
    var failWriteOne: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _failWriteOne }
        set { lock.lock(); defer { lock.unlock() }; _failWriteOne = newValue }
    }
    /// A failing write 1 still takes effect before it throws.
    var applyFailedWriteOne: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _applyFailedWriteOne }
        set { lock.lock(); defer { lock.unlock() }; _applyFailedWriteOne = newValue }
    }
    var failWriteZeroTimes: Int {
        get { lock.lock(); defer { lock.unlock() }; return _failWriteZeroTimes }
        set { lock.lock(); defer { lock.unlock() }; _failWriteZeroTimes = newValue }
    }

    func isDisabled() throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        if _failRead { throw FakeSleepSettingError() }
        return _value
    }

    func setDisabled(_ disabled: Bool) throws {
        let block = lock.withLock { () -> (started: DispatchSemaphore, gate: DispatchSemaphore)? in
            defer { _block = nil }
            return _block
        }
        if let block {
            block.started.signal()
            block.gate.wait()
        }
        lock.lock(); defer { lock.unlock() }
        _fileExistedAtAttempt.append(store.exists())
        if disabled, _failWriteOne {
            if _applyFailedWriteOne { _value = true }
            throw FakeSleepSettingError()
        }
        if !disabled, _failWriteZeroTimes > 0 { _failWriteZeroTimes -= 1; throw FakeSleepSettingError() }
        _value = disabled
        _writes.append(disabled)
        _fileExistedAtWrite.append(store.exists())
    }
}
