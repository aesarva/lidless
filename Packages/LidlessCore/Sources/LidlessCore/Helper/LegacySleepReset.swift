import Foundation
import os

/// App-side undo of a `disablesleep 1` left by a force-quit 0.2.0 closed-lid session. The 0.2.0
/// watchdog resets only while no process named Lidless runs, so it never does while 0.3.0 runs;
/// the daemon's `LegacyHelperCleaner` does when it starts, but a daemon the user never approves
/// never starts. Uses the 0.2.0 sudoers rule, which allows exactly this pmset call without a
/// password; runs as the user, so it never prompts.
public struct LegacySleepReset: Sendable {
    static let rule = "/etc/sudoers.d/lidless"
    static let command = ["/usr/bin/sudo", "-n", "/usr/bin/pmset", "-a", "disablesleep", "0"]
    private static let log = Logger(subsystem: HelperIDs.app, category: "helper")

    private let root: URL
    private let runner: CommandRunner

    public init(root: URL = URL(fileURLWithPath: "/"), runner: CommandRunner = ProcessCommandRunner()) {
        self.root = root
        self.runner = runner
    }

    private func fsPath(_ path: String) -> String {
        root.appendingPathComponent(path).path
    }

    /// Resets once when the 0.2.0 marker and sudoers rule are there, the daemon is not
    /// installed (it cleans up itself; one still being checked is registered all the same)
    /// and no other copy of Lidless (a 0.2.0 one, which owns its session) runs. Without the
    /// marker a 1 is someone else's and stays. Never throws: a failure is logged and the
    /// marker kept.
    public func resetIfNeeded(helperStatus: HelperStatus, otherCopyRunning: Bool) {
        let fm = FileManager.default
        let marker = fsPath(LegacyHelperCleaner.markerFile)
        guard fm.fileExists(atPath: marker), fm.fileExists(atPath: fsPath(Self.rule)),
              helperStatus != .installed, helperStatus != .checking, !otherCopyRunning else { return }
        let failure: String
        do {
            let result = try runner.run(Self.command[0], Array(Self.command.dropFirst()))
            if result.exitCode == 0 {
                do {
                    try fm.removeItem(atPath: marker)
                } catch {
                    Self.log.error("0.2.0 lid-mode marker not removed: \(error.localizedDescription, privacy: .public)")
                }
                Self.log.notice("reset disablesleep left by Lidless 0.2.0")
                return
            }
            failure = result.failureText("sudo pmset")
        } catch {
            failure = HelperError.message(for: error)
        }
        Self.log.error("resetting disablesleep left by Lidless 0.2.0 failed: \(failure, privacy: .public)")
    }
}
