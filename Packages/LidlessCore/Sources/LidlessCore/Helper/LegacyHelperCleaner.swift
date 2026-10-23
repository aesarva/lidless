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

    private static let markerName = "lid-mode.marker"

    private func failure(_ what: String, _ path: String, _ code: Int32) -> HelperError {
        .commandFailed("cannot \(what) \(path): \(String(cString: strerror(code)))")
    }

    /// Opens the marker directory without following a symlink. The descriptor pins the
    /// directory, so a swap for a symlink during the slow commands cannot redirect the
    /// marker steps. nil when there is no real directory; any other failure throws, so an
    /// unreadable directory is never mistaken for an absent marker.
    private func openMarkerDirectory() throws -> Int32? {
        let path = fsPath(Self.markerDirectory)
        var fd: Int32
        repeat { fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW) } while fd < 0 && errno == EINTR
        guard fd >= 0 else {
            let code = errno
            if [ENOENT, ENOTDIR, ELOOP].contains(code) { return nil }
            throw failure("open", path, code)
        }
        var st = stat()
        guard fstat(fd, &st) == 0 else {
            let code = errno
            close(fd)
            throw failure("stat", path, code)
        }
        guard (st.st_mode & S_IFMT) == S_IFDIR else {
            close(fd)
            return nil
        }
        return fd
    }

    /// Whether the marker entry exists in the pinned directory (a symlink counts).
    private func markerExists(in dirFd: Int32) throws -> Bool {
        var st = stat()
        if fstatat(dirFd, Self.markerName, &st, AT_SYMLINK_NOFOLLOW) == 0 { return true }
        let code = errno
        if code == ENOENT { return false }
        throw failure("stat", Self.markerFile, code)
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

    /// Returns the absolute paths of the files actually unlinked (the three legacy paths and
    /// the marker). The marker directory is removed too when empty, but is not reported.
    public func clean() throws -> [String] {
        let dirFd = try openMarkerDirectory()
        defer { if let dirFd { close(dirFd) } }

        if let dirFd, try markerExists(in: dirFd) {
            let result = try runner.run("/usr/bin/pmset", ["-a", "disablesleep", "0"])
            if result.exitCode != 0 { throw HelperError.commandFailed(result.failureText("pmset")) }
        }

        // 0 booted out, 3 / 113 not loaded. Anything else (or a timeout) aborts before deleting.
        let boot: CommandResult
        do {
            boot = try runner.run("/bin/launchctl", ["bootout", "system/app.lidless.watchdog"])
        } catch {
            throw HelperError.commandFailed("launchctl bootout failed: \(error)")
        }
        guard [0, 3, 113].contains(boot.exitCode) else {
            throw HelperError.commandFailed("launchctl bootout exited \(boot.exitCode): \(boot.stderr)")
        }

        var removed: [String] = []
        for path in Self.paths where try fsResult(path, unlink(fsPath(path))) { removed.append(path) }
        if let dirFd,
           try fsResult(Self.markerFile, unlinkat(dirFd, Self.markerName, 0)) {
            removed.append(Self.markerFile)
        }
        if dirFd != nil { _ = rmdir(fsPath(Self.markerDirectory)) }
        return removed
    }

    /// true when the call removed the entry, false for ENOENT, throws otherwise.
    private func fsResult(_ path: String, _ rc: Int32) throws -> Bool {
        if rc == 0 { return true }
        let code = errno
        if code == ENOENT { return false }
        throw HelperError.commandFailed("cannot remove \(path): \(String(cString: strerror(code)))")
    }
}
