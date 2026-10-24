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
    private var _generation: UInt64 = 1

    /// The connection generation `setSleepDisabled` reports.
    var generation: UInt64 {
        get { lock.withLock { _generation } }
        set { lock.withLock { _generation = newValue } }
    }

    var stubStatus: HelperStatus {
        get { lock.lock(); defer { lock.unlock() }; return _status }
        set { lock.lock(); defer { lock.unlock() }; _status = newValue }
    }
    var failNextSet: HelperError? {
        get { lock.lock(); defer { lock.unlock() }; return _failNextSet }
        set { lock.lock(); defer { lock.unlock() }; _failNextSet = newValue }
    }
    var setCalls: [Bool] { lock.lock(); defer { lock.unlock() }; return _setCalls }

    private var _legacyPresent = false
    private var _removeLegacyError: HelperError?
    private var _removeLegacyCalls = 0
    private var _refreshInfoCalls = 0
    /// What `legacyHelperPresent()` answers; a successful `removeLegacyHelper()` clears it.
    var legacyPresent: Bool {
        get { lock.withLock { _legacyPresent } }
        set { lock.withLock { _legacyPresent = newValue } }
    }
    /// Thrown by every `removeLegacyHelper()` while set.
    var removeLegacyError: HelperError? {
        get { lock.withLock { _removeLegacyError } }
        set { lock.withLock { _removeLegacyError = newValue } }
    }
    var removeLegacyCalls: Int { lock.withLock { _removeLegacyCalls } }
    var refreshInfoCalls: Int { lock.withLock { _refreshInfoCalls } }
    private var _statusAfterRefresh: HelperStatus?
    /// The status the next `refreshInfo()` finds (e.g. a re-registered daemon answering).
    var statusAfterRefresh: HelperStatus? {
        get { lock.withLock { _statusAfterRefresh } }
        set { lock.withLock { _statusAfterRefresh = newValue } }
    }

    private var _lastInfo: HelperInfo?
    /// What `lastInfo()` and `freshInfo()` answer.
    var stubInfo: HelperInfo? {
        get { lock.withLock { _lastInfo } }
        set { lock.withLock { _lastInfo = newValue } }
    }

    private var _freshInfoError: HelperError?
    /// Thrown by `freshInfo()` while set; `lastInfo()` still answers `stubInfo`.
    var freshInfoError: HelperError? {
        get { lock.withLock { _freshInfoError } }
        set { lock.withLock { _freshInfoError = newValue } }
    }

    private var _holdSets = false
    private let setGate = DispatchSemaphore(value: 0)
    /// While set, each `setSleepDisabled` waits for a `releaseSet()` (a slow daemon). The call
    /// is recorded, and its connection's generation taken, before it waits.
    var holdSets: Bool {
        get { lock.withLock { _holdSets } }
        set { lock.withLock { _holdSets = newValue } }
    }
    /// Lets one waiting (or the next) `setSleepDisabled` go on.
    func releaseSet() { setGate.signal() }

    private var _statusScript: [HelperStatus] = []
    /// Answers for the next `status()` calls, in order; then `stubStatus` again. The
    /// acquisition guard in `setSleepDisabled` always reads `stubStatus`.
    var statusScript: [HelperStatus] {
        get { lock.withLock { _statusScript } }
        set { lock.withLock { _statusScript = newValue } }
    }
    private var _freshInfoCalls = 0
    var freshInfoCalls: Int { lock.withLock { _freshInfoCalls } }

    private var _daemonMayRunOverride: Bool?
    /// What `daemonMayRun` answers; nil: a daemon may run while `stubStatus` is `.installed`,
    /// `.checking` or `.error` (registered and enabled).
    var daemonMayRunOverride: Bool? {
        get { lock.withLock { _daemonMayRunOverride } }
        set { lock.withLock { _daemonMayRunOverride = newValue } }
    }

    func status() -> HelperStatus {
        lock.withLock { _statusScript.isEmpty ? _status : _statusScript.removeFirst() }
    }
    var daemonMayRun: Bool {
        lock.withLock {
            if let _daemonMayRunOverride { return _daemonMayRunOverride }
            switch _status {
            case .installed, .checking, .error: return true
            case .notInstalled, .needsApproval, .unsigned: return false
            }
        }
    }
    func lastInfo() -> HelperInfo? { stubInfo }
    func freshInfo() throws -> HelperInfo {
        lock.withLock { _freshInfoCalls += 1 }
        if let error = freshInfoError { throw error }
        guard let info = stubInfo else { throw HelperError.commandFailed("no info") }
        return info
    }
    func refreshInfo() {
        lock.withLock {
            _refreshInfoCalls += 1
            if let next = _statusAfterRefresh {
                _status = next
                _statusAfterRefresh = nil
            }
        }
    }
    func install() throws {}
    func uninstall() throws {}
    func legacyHelperPresent() -> Bool { legacyPresent }
    func removeLegacyHelper() throws -> [String] {
        try lock.withLock {
            _removeLegacyCalls += 1
            if let error = _removeLegacyError { throw error }
            _legacyPresent = false
            return ["/etc/sudoers.d/lidless"]
        }
    }
    func openSystemSettings() {}
    /// Like `DaemonBackend`: taking the hold is refused, unsent, unless `stubStatus` is
    /// `.installed`.
    func setSleepDisabled(_ disabled: Bool) throws -> UInt64 {
        let (generation, waits) = try lock.withLock { () -> (UInt64, Bool) in
            if disabled, _status != .installed { throw HelperError.notReady }
            _setCalls.append(disabled)
            return (_generation, _holdSets)
        }
        if waits { setGate.wait() }
        let failure = lock.withLock { () -> HelperError? in
            defer { _failNextSet = nil }
            return _failNextSet
        }
        if let failure { throw failure }
        return generation
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
    private var _outstanding: PendingUnregister?
    private var _calls: [String] = []
    private var _unregisterHangs = false

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
    /// `startUnregister` holds its completion until `completeUnregister()`.
    var unregisterHangs: Bool {
        get { lock.withLock { _unregisterHangs } }
        set { lock.withLock { _unregisterHangs = newValue } }
    }
    /// "register", "unregister" and "startUnregister", in call order.
    var calls: [String] { lock.withLock { _calls } }
    var registerCalls: Int { lock.withLock { _registerCalls } }
    /// Both `unregister()` and `startUnregister()`.
    var unregisterCalls: Int { lock.withLock { _unregisterCalls } }
    var openSettingsCalls: Int { lock.withLock { _openSettingsCalls } }

    var status: RegistrationStatus { stubStatus }

    func register() throws {
        onRegister?()
        lock.lock(); defer { lock.unlock() }
        _registerCalls += 1
        _calls.append("register")
        if let _registerError { throw _registerError }
        _status = _statusAfterRegister ?? .enabled
    }

    func unregister() throws {
        lock.withLock {
            _unregisterCalls += 1
            _calls.append("unregister")
            _status = .notRegistered
        }
    }

    func startUnregister() -> PendingUnregister {
        let pending = PendingUnregister()
        let hangs = lock.withLock { () -> Bool in
            _calls.append("startUnregister")
            _unregisterCalls += 1
            if _unregisterHangs { _outstanding = pending }
            return _unregisterHangs
        }
        if !hangs { finish(pending) }
        return pending
    }

    /// Launchd's completion of the hung `startUnregister`. The status flips with it unless
    /// `statusFollows` is false (it can change before or after the handler runs).
    func completeUnregister(error: Error? = nil, statusFollows: Bool = true) {
        guard let pending = lock.withLock({ () -> PendingUnregister? in
            defer { _outstanding = nil }
            return _outstanding
        }) else { return }
        finish(pending, error: error, flipStatus: statusFollows)
    }

    private func finish(_ pending: PendingUnregister, error: Error? = nil, flipStatus: Bool = true) {
        if error == nil && flipStatus { lock.withLock { _status = .notRegistered } }
        pending.complete(error)
    }

    func openSystemSettings() { lock.withLock { _openSettingsCalls += 1 } }
}

final class FakeHelperClient: HelperClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _info = HelperInfo(version: "0.3.0", build: "1", sleepDisabled: false, owned: false)
    private var _infoError: Error?
    private var _setError: Error?
    private var _setCalls: [Bool] = []
    private var _infoCalls = 0
    private var _removeLegacyResult: Result<[String], HelperError> = .success([])
    private var _lostHandler: (@Sendable (UInt64) -> Void)?
    private var _generation: UInt64 = 1
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

    var onConnectionLost: (@Sendable (UInt64) -> Void)? {
        get { lock.withLock { _lostHandler } }
        set { lock.withLock { _lostHandler = newValue } }
    }
    var generation: UInt64 {
        get { lock.withLock { _generation } }
        set { lock.withLock { _generation = newValue } }
    }

    func setSleepDisabled(_ disabled: Bool) throws -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        _setCalls.append(disabled)
        if let _setError { throw _setError }
        return _generation
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

/// `PollScheduler` driven by hand: `fire()` runs every active poll once.
@MainActor final class ManualPollScheduler: PollScheduler {
    final class Handle: PollHandle {
        let tick: @MainActor () -> Void
        var cancelled = false
        init(tick: @escaping @MainActor () -> Void) { self.tick = tick }
        func cancel() { cancelled = true }
    }
    var handles: [Handle] = []
    var intervals: [TimeInterval] = []
    var active: [Handle] { handles.filter { !$0.cancelled } }

    func startPolling(every interval: TimeInterval, _ tick: @escaping @MainActor () -> Void) -> PollHandle {
        let handle = Handle(tick: tick)
        handles.append(handle)
        intervals.append(interval)
        return handle
    }

    func fire() { for h in active { h.tick() } }
}

@MainActor final class FakeNotifier: Notifier {
    var posted: [WakeNotification] = []
    var cancelEndingSoonCount = 0
    func post(_ n: WakeNotification) { posted.append(n) }
    func cancelEndingSoon() { cancelEndingSoonCount += 1 }
}

/// The helper service as the controller sees it. Like the service, an acquisition that could
/// only be refused (the helper is not `.installed`) is answered `helperNotReady` at once and
/// never shows as pending. With `autoConfirm` each wish is answered at once, as the service
/// would answer it: an acquisition only for a verified helper, a release without a call when
/// no daemon is registered. Without it the test answers with `deliver`.
@MainActor final class FakeLid: LidSleepControlling {
    var status: HelperStatus = .installed
    var onChange: ((LidHold) -> Void)?
    private(set) var hold = LidHold()
    /// Every `setWanted`, in order.
    var wanted: [Bool] = []
    var autoConfirm = true
    /// With `autoConfirm`: acquisitions fail.
    var failEnable = false
    /// With `autoConfirm`: releases sent to the daemon fail and the hold stays as it was.
    var failDisable = false
    /// With `autoConfirm`: acquisitions sent to a verified helper (failed ones too).
    var acquireCalls = 0
    /// With `autoConfirm`: releases sent to a registered daemon (failed ones too).
    var releaseCalls = 0
    var retryCalls = 0
    var lostGenerations: [UInt64] = []
    /// Whether `connectionLost(generation:)` ends a confirmed hold.
    var lossAffectsHold = true
    /// What `confirmReleased` answers.
    var confirmResult = true
    var confirmCalls = 0
    /// `confirmReleasedForRemoval` calls, answered like `confirmReleased`.
    var removalConfirmCalls = 0
    /// `confirmReleased` and `confirmReleasedForRemoval` wait for `deliverConfirm()`.
    var holdConfirm = false
    private var heldConfirm: (wishes: Int, done: @MainActor (Bool) -> Void)?

    func helperStatus() -> HelperStatus { status }

    func setWanted(_ wanted: Bool) {
        self.wanted.append(wanted)
        guard canSend(wanted: wanted, held: hold.held) else {
            deliver(held: false, failure: LidHold.helperNotReady)
            return
        }
        deliver(held: hold.held, pending: wanted != hold.held)
        if autoConfirm { converge() }
    }

    func deliver(held: Bool, pending: Bool = false, failure: String? = nil) {
        hold = LidHold(held: held, pending: pending, failure: failure)
        onChange?(hold)
    }

    func retry() {
        retryCalls += 1
        let wish = wanted.last ?? false
        guard hold.failure != nil || wish != hold.held, canSend(wanted: wish, held: hold.held) else { return }
        deliver(held: hold.held, pending: wish != hold.held)
        if autoConfirm { converge() }
    }

    func confirmReleased(_ done: @escaping @MainActor (Bool) -> Void) {
        confirmCalls += 1
        if holdConfirm {
            heldConfirm = (wanted.count, done)
        } else {
            answerConfirm(done)
        }
    }

    func confirmReleasedForRemoval(_ done: @escaping @MainActor (Bool) -> Void) {
        removalConfirmCalls += 1
        if holdConfirm {
            heldConfirm = (wanted.count, done)
        } else {
            answerConfirm(done)
        }
    }

    /// Answers the held confirmation, unless a newer wish came since (like the service).
    func deliverConfirm() {
        guard let pending = heldConfirm else { return }
        heldConfirm = nil
        guard pending.wishes == wanted.count else { return }
        answerConfirm(pending.done)
    }

    func connectionLost(generation: UInt64) {
        lostGenerations.append(generation)
        guard lossAffectsHold, hold.held else { return }
        let wish = wanted.last ?? false
        guard canSend(wanted: wish, held: false) else {
            deliver(held: false, failure: LidHold.helperNotReady)
            return
        }
        deliver(held: false, pending: wish)
        if autoConfirm, wish { converge() }
    }

    private func canSend(wanted: Bool, held: Bool) -> Bool {
        !wanted || held || status == .installed
    }

    private func answerConfirm(_ done: @MainActor (Bool) -> Void) {
        // A daemon that holds nothing has reached the wish "no", whatever the last release said.
        if confirmResult, !(wanted.last ?? false), hold.failure != nil { deliver(held: false) }
        done(confirmResult)
    }

    private func converge() {
        if wanted.last ?? false {
            guard status == .installed else {
                deliver(held: hold.held, failure: LidHold.helperNotReady)
                return
            }
            acquireCalls += 1
            if failEnable {
                deliver(held: false, failure: "enable failed")
            } else {
                deliver(held: true)
            }
        } else {
            switch status {
            case .installed, .error, .checking:
                releaseCalls += 1
                if failDisable {
                    deliver(held: hold.held, failure: "disable failed")
                    return
                }
            case .notInstalled, .needsApproval, .unsigned:
                break
            }
            deliver(held: false)
        }
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
