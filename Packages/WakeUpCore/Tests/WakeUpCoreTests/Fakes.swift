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
