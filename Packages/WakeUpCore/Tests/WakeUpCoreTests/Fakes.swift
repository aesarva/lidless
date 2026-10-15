import Foundation
@testable import WakeUpCore

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

    func run(_ executable: String, _ arguments: [String]) throws -> CommandResult {
        lock.lock(); defer { lock.unlock() }
        _calls.append([executable] + arguments)
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
    func install() throws {}
    func uninstall() throws {}
    func setSleepDisabled(_ disabled: Bool) throws {
        lock.lock(); defer { lock.unlock() }
        _setCalls.append(disabled)
        if let e = _failNextSet { _failNextSet = nil; throw e }
    }
    func isSleepDisabled() throws -> Bool { lock.lock(); defer { lock.unlock() }; return _setCalls.last ?? false }
}
