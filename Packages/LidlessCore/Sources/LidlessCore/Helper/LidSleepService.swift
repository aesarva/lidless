import Foundation
import os

@MainActor public protocol LidSleepControlling: AnyObject {
    func helperStatus() -> HelperStatus
    func enable() throws
    func disable() throws
    /// Resets sleep if the lid-mode marker is present. Returns true when no marker is present
    /// or the reset succeeded, false when the reset failed (disablesleep may still be 1).
    @discardableResult func recoverIfNeeded() -> Bool
}

@MainActor public final class LidSleepService: LidSleepControlling {
    public static let defaultMarkerURL = URL(fileURLWithPath: SudoersBackend.markerPath)

    private let backend: PrivilegedBackend
    private let markerURL: URL
    private let log = Logger(subsystem: "io.github.alexsarva.Lidless", category: "helper")

    public init(backend: PrivilegedBackend, markerURL: URL = LidSleepService.defaultMarkerURL) {
        self.backend = backend
        self.markerURL = markerURL
    }

    public func helperStatus() -> HelperStatus { backend.status() }

    public func enable() throws {
        let fm = FileManager.default
        // A marker left by an earlier failed disable means disablesleep may still be 1:
        // it is the only way back to 0, so a failed enable must not remove it.
        let existed = fm.fileExists(atPath: markerURL.path)
        try fm.createDirectory(at: markerURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("1".utf8).write(to: markerURL)
        do {
            try backend.setSleepDisabled(true)
        } catch {
            if !existed { try? fm.removeItem(at: markerURL) }
            throw error
        }
    }

    public func disable() throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: markerURL.path) else { return }
        try backend.setSleepDisabled(false)
        try fm.removeItem(at: markerURL)
    }

    @discardableResult
    public func recoverIfNeeded() -> Bool {
        guard FileManager.default.fileExists(atPath: markerURL.path) else { return true }
        log.notice("Stale lid-mode marker found; resetting sleep")
        do {
            try disable()
            return true
        } catch {
            log.error("Recovery failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }
}
