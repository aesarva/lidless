import Foundation

public struct CommandResult: Equatable, Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String

    public init(exitCode: Int32, stdout: String, stderr: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

public enum CommandError: Error, Equatable {
    /// The command ran past its time limit and was killed.
    case timedOut(String)
}

public protocol CommandRunner: Sendable {
    /// Runs a command and waits for it. `timeout: nil` waits as long as it takes
    /// (an administrator password prompt); otherwise a slower command is killed.
    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval?) throws -> CommandResult
}

public extension CommandRunner {
    /// Non-interactive commands (sudo -n, pmset) finish in milliseconds; a hung one must not
    /// hold the caller (often the main actor, with the safety checks) for good.
    static var defaultTimeout: TimeInterval { 15 }

    func run(_ executable: String, _ arguments: [String]) throws -> CommandResult {
        try run(executable, arguments, timeout: Self.defaultTimeout)
    }
}

/// Runs a command with `Foundation.Process` and waits for it to finish.
public struct ProcessCommandRunner: CommandRunner {
    public init() {}

    public func run(_ executable: String, _ arguments: [String], timeout: TimeInterval?) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        // Not waitUntilExit(): it spins the current run loop, so on the main thread timers and
        // main-queue work would run re-entrantly in the middle of the caller's state change.
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()

        // Drain both pipes concurrently so a chatty child cannot block on a full pipe.
        final class Box: @unchecked Sendable { var data = Data() }
        let outBox = Box(), errBox = Box()
        let group = DispatchGroup()
        for (pipe, box) in [(out, outBox), (err, errBox)] {
            group.enter()
            DispatchQueue.global().async {
                box.data = pipe.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }
        }

        let deadline: DispatchTime = timeout.map { .now() + $0 } ?? .distantFuture
        if exited.wait(timeout: deadline) == .timedOut {
            process.terminate()
            if exited.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                exited.wait()
            }
            // A grandchild may still hold a pipe open; the output is not needed any more.
            _ = group.wait(timeout: .now() + 2)
            throw CommandError.timedOut(([executable] + arguments).joined(separator: " "))
        }
        group.wait()
        return CommandResult(
            exitCode: process.terminationStatus,
            stdout: String(decoding: outBox.data, as: UTF8.self),
            stderr: String(decoding: errBox.data, as: UTF8.self)
        )
    }
}
