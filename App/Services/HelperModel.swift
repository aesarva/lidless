import Foundation
import Observation
import LidlessCore

/// Observable wrapper around the privileged backend for the UI (helper install state).
@MainActor @Observable final class HelperModel {
    @ObservationIgnored private let backend: PrivilegedBackend
    private(set) var status: HelperStatus
    private(set) var isWorking = false
    @ObservationIgnored private var refreshingInfo = false

    init(backend: PrivilegedBackend) {
        self.backend = backend
        self.status = backend.status()
    }

    /// Updates the status now, then again once the daemon has answered in the background.
    func refresh() {
        updateStatus()
        guard !refreshingInfo else { return }
        refreshingInfo = true
        let backend = self.backend
        Task {
            await Task.detached { backend.refreshInfo() }.value
            refreshingInfo = false
            updateStatus()
        }
    }

    private func updateStatus() {
        // Observation does not compare values: an equal assignment would still redraw.
        let current = backend.status()
        if current != status { status = current }
    }

    func install() async -> HelperError? {
        await run { try $0.install() }
    }

    func uninstall() async -> HelperError? {
        await run { try $0.uninstall() }
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
}
