import Foundation
import Observation
import os
import LidlessCore

/// Observable wrapper around the privileged backend for the UI: helper state, the wait for
/// approval in System Settings and the one-time removal of the 0.2.0 helper.
@MainActor @Observable final class HelperModel {
    @ObservationIgnored private let backend: PrivilegedBackend
    private(set) var status: HelperStatus
    private(set) var isWorking = false
    /// The 0.2.0 sudoers helper was removed during this run.
    private(set) var legacyRemoved = false
    /// Called when the status turns `.installed`, after the 0.2.0 cleanup that transition runs.
    @ObservationIgnored var onBecameInstalled: (() -> Void)?
    /// Whether this app holds closed-lid mode now: the daemon refuses the 0.2.0 cleanup then.
    @ObservationIgnored var lidModeHeld: () -> Bool = { false }
    @ObservationIgnored private var refreshingInfo = false
    @ObservationIgnored private var approvalTimer: Timer?
    @ObservationIgnored private var migration: Task<Void, Never>?
    /// The 0.2.0 helper is gone (removed or never there): no more checks this run.
    @ObservationIgnored private var legacyDone = false
    @ObservationIgnored private let log = Logger(subsystem: HelperIDs.app, category: "helper")

    init(backend: PrivilegedBackend) {
        self.backend = backend
        self.status = backend.status()
    }

    /// Updates the status now, then again once the daemon has answered in the background.
    func refresh() {
        updateStatus(retryMigration: true)
        guard !refreshingInfo else { return }
        refreshingInfo = true
        let backend = self.backend
        Task {
            await Task.detached { backend.refreshInfo() }.value
            refreshingInfo = false
            // A failed cleanup is retried at most once per refresh: the first update did that.
            updateStatus(retryMigration: false)
        }
    }

    private func updateStatus(retryMigration: Bool) {
        let current = backend.status()
        let becameInstalled = current == .installed && status != .installed
        // Observation does not compare values: an equal assignment would still redraw.
        if current != status { status = current }
        updateApprovalPolling()
        if becameInstalled {
            // Lid mode must not be turned on before the 0.2.0 cleanup has had its turn.
            if let migration = migrateIfNeeded() {
                Task {
                    await migration.value
                    onBecameInstalled?()
                }
            } else {
                onBecameInstalled?()
            }
        } else if current == .installed, retryMigration {
            migrateIfNeeded()
        }
    }

    /// Polls once a second while macOS waits for the user's approval, so lid mode turns on
    /// as soon as they allow it (a menu-bar app is not told when they come back).
    private func updateApprovalPolling() {
        guard status == .needsApproval else {
            approvalTimer?.invalidate()
            approvalTimer = nil
            return
        }
        guard approvalTimer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        approvalTimer = timer
    }

    /// Removes the 0.2.0 helper through the daemon if it is still there. Returns the running
    /// removal, or nil when there is nothing to wait for. A failure (lid mode held, daemon
    /// exiting, no answer) is only logged; a later refresh tries again.
    @discardableResult
    private func migrateIfNeeded() -> Task<Void, Never>? {
        if let migration { return migration }
        guard !legacyDone else { return nil }
        guard backend.legacyHelperPresent() else {
            legacyDone = true
            return nil
        }
        guard !lidModeHeld() else { return nil }
        let backend = self.backend
        let task = Task {
            let outcome = await Task.detached { () -> MigrationOutcome in
                do {
                    return .removed(try backend.removeLegacyHelper())
                } catch {
                    return .failed(HelperError.message(for: error))
                }
            }.value
            switch outcome {
            case .removed(let paths):
                log.notice("removed the 0.2.0 helper: \(paths.joined(separator: ", "), privacy: .public)")
                legacyDone = true
                legacyRemoved = true
            case .failed(let message):
                log.error("removing the 0.2.0 helper failed: \(message, privacy: .public)")
            }
            migration = nil
        }
        migration = task
        return task
    }

    /// At launch with the daemon already allowed: removes a 0.2.0 helper still present, then
    /// calls `then` (right away when there is nothing to remove).
    func removeLegacyHelperAtLaunch(then: @escaping () -> Void) {
        guard status == .installed, let migration = migrateIfNeeded() else {
            then()
            return
        }
        Task {
            await migration.value
            then()
        }
    }

    private enum MigrationOutcome: Sendable {
        case removed([String])
        case failed(String)
    }

    /// Registers the daemon (macOS opens Login Items when it needs approval). Returns after
    /// any 0.2.0 cleanup that the registration started.
    func install() async -> HelperError? {
        let error = await run { try $0.install() }
        await migration?.value
        return error
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
    /// Snapshot exporter: show the "0.2.0 helper was removed" line.
    func markLegacyRemovedForPreview() { legacyRemoved = true }
    #endif
}
