import Foundation

/// Removes the 0.2.0 install (sudoers rule, watchdog daemon and script, lid-mode marker).
/// Runs as root, so every filesystem step uses lstat/unlink/rmdir and never follows a symlink;
/// `/Users/Shared` is writable by any user, which makes the marker directory untrusted.
public struct LegacyHelperCleaner: Sendable {
    static let paths = [
        "/etc/sudoers.d/lidless",
        "/Library/LaunchDaemons/app.lidless.watchdog.plist",
        "/Library/PrivilegedHelperTools/app.lidless.watchdog.sh",
    ]
    static let markerDirectory = "/Users/Shared/Lidless"
    static let markerFile = markerDirectory + "/lid-mode.marker"

    private let root: URL
    private let runner: CommandRunner

    public init(root: URL = URL(fileURLWithPath: "/"), runner: CommandRunner = ProcessCommandRunner()) {
        self.root = root
        self.runner = runner
    }

    private func fsPath(_ path: String) -> String {
        root.appendingPathComponent(path).path
    }

    private func isRealDirectory(_ path: String) -> Bool {
        var st = stat()
        return lstat(fsPath(path), &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
    }

    /// lstat: a dangling symlink exists.
    private func exists(_ path: String) -> Bool {
        var st = stat()
        return lstat(fsPath(path), &st) == 0
    }

    /// True when any of the 0.2.0 files is still there (a dangling symlink counts).
    public func isPresent() -> Bool {
        Self.paths.contains(where: exists)
    }

    /// Returns the absolute paths removed: the files, the marker and the marker directory
    /// (the last only when it was a real, empty directory).
    public func clean() throws -> [String] {
        let markerDirIsReal = isRealDirectory(Self.markerDirectory)
        if markerDirIsReal, exists(Self.markerFile) {
            let result = try runner.run("/usr/bin/pmset", ["-a", "disablesleep", "0"])
            if result.exitCode != 0 { throw HelperError.commandFailed(result.stderr) }
        }
        // Not loaded is fine.
        _ = try? runner.run("/bin/launchctl", ["bootout", "system/app.lidless.watchdog"])

        var removed: [String] = []
        var targets = Self.paths
        if markerDirIsReal { targets.append(Self.markerFile) }
        for path in targets where try unlinkIfPresent(path) { removed.append(path) }

        if markerDirIsReal, rmdir(fsPath(Self.markerDirectory)) == 0 {
            removed.append(Self.markerDirectory)
        }
        return removed
    }

    private func unlinkIfPresent(_ path: String) throws -> Bool {
        if unlink(fsPath(path)) == 0 { return true }
        let code = errno
        if code == ENOENT { return false }
        throw HelperError.commandFailed("cannot remove \(path): \(String(cString: strerror(code)))")
    }
}
