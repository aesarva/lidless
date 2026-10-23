import Foundation
import Observation
import LidlessCore

/// Observable face of `HelperCoordinator` for the UI, plus the install and remove actions.
@MainActor @Observable final class HelperModel {
    @ObservationIgnored private let backend: PrivilegedBackend
    @ObservationIgnored private let coordinator: HelperCoordinator
    private(set) var status: HelperStatus
    private(set) var isWorking = false
    /// The 0.2.0 sudoers helper was there earlier in this launch and is gone now.
    private(set) var legacyRemoved = false
    /// Why removing the 0.2.0 helper failed (the daemon retries when it next starts).
    private(set) var legacyError: String?
    /// The daemon's last answer (version and build on the Helper tab).
    private(set) var daemonInfo: HelperInfo?

    /// Called when the status turns `.installed`.
    var onBecameInstalled: (() -> Void)? {
        get { coordinator.onBecameInstalled }
        set { coordinator.onBecameInstalled = newValue }
    }

    /// `lidModeHeld`: whether this app holds closed-lid mode now (the daemon refuses the 0.2.0
    /// removal then).
    init(backend: PrivilegedBackend, lidModeHeld: @escaping @MainActor () -> Bool = { false },
         scheduler: PollScheduler = RunLoopPollScheduler()) {
        self.backend = backend
        coordinator = HelperCoordinator(backend: backend, scheduler: scheduler, lidModeHeld: lidModeHeld)
        status = coordinator.status
        daemonInfo = backend.lastInfo()
        coordinator.onChange = { [weak self] in self?.sync() }
    }

    /// Updates the status now, then again once the daemon has answered in the background.
    func refresh() {
        coordinator.refresh()
    }

    private func sync() {
        // Observation does not compare values: an equal assignment would still redraw.
        if status != coordinator.status { status = coordinator.status }
        if legacyRemoved != coordinator.legacyRemoved { legacyRemoved = coordinator.legacyRemoved }
        if legacyError != coordinator.legacyError { legacyError = coordinator.legacyError }
        let info = backend.lastInfo()
        if daemonInfo != info { daemonInfo = info }
    }

    /// Registers the daemon; macOS opens Login Items when it needs the user's approval.
    func install() async -> HelperError? {
        await run { try $0.install() }
    }

    func uninstall() async -> HelperError? {
        await run { try $0.uninstall() }
    }

    func openSystemSettings() {
        backend.openSystemSettings()
    }

    private func run(_ work: @escaping @Sendable (PrivilegedBackend) throws -> Void) async -> HelperError? {
        isWorking = true
        defer { isWorking = false }
        let backend = self.backend
        let result: HelperError? = await Task.detached {
            do {
                try work(backend)
                return nil
            } catch let error as HelperError {
                return error
            } catch {
                return .commandFailed(String(describing: error))
            }
        }.value
        refresh()
        return result
    }

    #if DEBUG
    /// Snapshot exporter: show the 0.2.0 removal line or its error.
    func previewLegacy(removed: Bool, error: String? = nil) {
        legacyRemoved = removed
        legacyError = error
    }
    #endif
}
