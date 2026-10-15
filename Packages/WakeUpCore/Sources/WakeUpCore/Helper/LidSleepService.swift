import Foundation
import os

@MainActor public protocol LidSleepControlling: AnyObject {
    func helperStatus() -> HelperStatus
    func enable() throws
    func disable() throws
    func recoverIfNeeded()
}

@MainActor public final class LidSleepService: LidSleepControlling {
    public static let defaultMarkerURL = URL(fileURLWithPath: SudoersBackend.markerPath)

    private let backend: PrivilegedBackend
    private let markerURL: URL
    private let log = Logger(subsystem: "io.github.alexsarva.WakeUp", category: "helper")

    public init(backend: PrivilegedBackend, markerURL: URL = LidSleepService.defaultMarkerURL) {
        self.backend = backend
        self.markerURL = markerURL
    }

    public func helperStatus() -> HelperStatus { backend.status() }

    public func enable() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: markerURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("1".utf8).write(to: markerURL)
        do {
            try backend.setSleepDisabled(true)
        } catch {
            try? fm.removeItem(at: markerURL)
            throw error
        }
    }

    public func disable() throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: markerURL.path) else { return }
        try backend.setSleepDisabled(false)
        try fm.removeItem(at: markerURL)
    }

    public func recoverIfNeeded() {
        guard FileManager.default.fileExists(atPath: markerURL.path) else { return }
        log.notice("Stale lid-mode marker found; resetting sleep")
        do {
            try disable()
        } catch {
            log.error("Recovery failed: \(String(describing: error), privacy: .public)")
        }
    }
}
