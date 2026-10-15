import Foundation

public final class SudoersBackend: PrivilegedBackend {
    public static let sudoersPath = "/etc/sudoers.d/wakeup"
    public static let watchdogScriptPath = "/Library/PrivilegedHelperTools/app.wakeup.watchdog.sh"
    public static let watchdogPlistPath = "/Library/LaunchDaemons/app.wakeup.watchdog.plist"
    public static let markerPath = "/Users/Shared/WakeUp/lid-mode.marker"

    private let runner: CommandRunner
    private let helperDirectory: URL
    private let userName: String
    private let fileExists: @Sendable (String) -> Bool

    public init(runner: CommandRunner, helperDirectory: URL, userName: String,
                fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) {
        self.runner = runner
        self.helperDirectory = helperDirectory
        self.userName = userName
        self.fileExists = fileExists
    }

    // MARK: PrivilegedBackend

    public func status() -> HelperStatus {
        do {
            let r = try runner.run("/usr/bin/sudo", ["-n", "-l", "/usr/bin/pmset", "-a", "disablesleep", "1"])
            guard r.exitCode == 0 else { return .notInstalled }
            let present = fileExists(Self.watchdogScriptPath) && fileExists(Self.watchdogPlistPath)
            return present ? .installed : .error("watchdog missing")
        } catch {
            return .error(String(describing: error))
        }
    }

    public func setSleepDisabled(_ disabled: Bool) throws {
        let r = try runner.run("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-a", "disablesleep", disabled ? "1" : "0"])
        if r.exitCode != 0 { throw HelperError.commandFailed(r.stderr) }
    }

    public func isSleepDisabled() throws -> Bool {
        let r = try runner.run("/usr/bin/pmset", ["-g"])
        if r.exitCode != 0 { throw HelperError.commandFailed(r.stderr) }
        return PmsetParser.sleepDisabled(in: r.stdout)
    }

    public func install() throws {
        let rule = try SudoersRule.render(userName: userName)
        try runPrivileged(installCommand(ruleText: rule))
    }

    public func uninstall() throws {
        let script = helperDirectory.appendingPathComponent("uninstall.sh").path
        try runPrivileged("/bin/bash " + [script, Self.markerPath].map(Self.shellQuote).joined(separator: " "))
    }

    // MARK: Helpers

    private func runPrivileged(_ shellCommand: String) throws {
        let script = "do shell script " + Self.appleScriptString(shellCommand) + " with administrator privileges"
        let r = try runner.run("/usr/bin/osascript", ["-e", script])
        if r.exitCode == 0 { return }
        if r.stderr.contains("(-128)") { throw HelperError.cancelled }
        throw HelperError.installFailed(r.stderr)
    }

    /// Contract with install.sh: `install.sh <sudoers_rule_text> <user> <helper_dir>`.
    /// The rule text is passed inline so the app never writes a file that root later trusts.
    func installCommand(ruleText: String) -> String {
        let script = helperDirectory.appendingPathComponent("install.sh").path
        let args = [script, ruleText, userName, helperDirectory.path]
        return "/bin/bash " + args.map(Self.shellQuote).joined(separator: " ")
    }

    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func appleScriptString(_ s: String) -> String {
        let escaped = s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"" + escaped + "\""
    }
}
