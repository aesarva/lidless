import Foundation

public protocol SleepSetting: Sendable {
    func isDisabled() throws -> Bool
    func setDisabled(_ disabled: Bool) throws
}

/// The real `disablesleep` setting, read and written through pmset.
public struct PmsetSleepSetting: SleepSetting {
    private let runner: CommandRunner

    public init(runner: CommandRunner = ProcessCommandRunner()) { self.runner = runner }

    public func isDisabled() throws -> Bool {
        let result = try runner.run("/usr/bin/pmset", ["-g"])
        guard result.exitCode == 0 else { throw HelperError.commandFailed(result.failureText("pmset")) }
        return PmsetParser.sleepDisabled(in: result.stdout)
    }

    public func setDisabled(_ disabled: Bool) throws {
        let result = try runner.run("/usr/bin/pmset", ["-a", "disablesleep", disabled ? "1" : "0"])
        guard result.exitCode == 0 else { throw HelperError.commandFailed(result.failureText("pmset")) }
    }
}
