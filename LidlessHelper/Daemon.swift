import Foundation
import LidlessCore
import os

/// Accepts connections and decides when the daemon may exit.
///
/// The connection counter and both timers live on `queue`. SleepGuard calls may block for
/// seconds (pmset), which is fine there and on XPC queues; the listener delegate only
/// enqueues, never waits for them.
final class Daemon: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private static let log = Logger(subsystem: HelperIDs.helper, category: "daemon")
    private static let idleExitDelay: DispatchTimeInterval = .seconds(10)
    private static let retryInterval: DispatchTimeInterval = .seconds(15)

    private let sleepGuard: SleepGuard
    private let cleaner: LegacyHelperCleaner
    private let version: String
    /// nil when the daemon has no Team ID (ad-hoc build): every connection is refused.
    private let clientRequirement = CodeSigningRequirement.requirement(
        identifier: HelperIDs.app, teamID: CodeSigningRequirement.ownTeamID()
    )

    private let queue = DispatchQueue(label: "io.github.aesarva.Lidless.helper.lifecycle")
    // Accessed only on `queue`.
    private var connections = 0
    private var idleTimer: DispatchSourceTimer?
    private var retryTimer: DispatchSourceTimer?

    init(guard sleepGuard: SleepGuard, cleaner: LegacyHelperCleaner, version: String) {
        self.sleepGuard = sleepGuard
        self.cleaner = cleaner
        self.version = version
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard let clientRequirement else {
            Self.log.error("no Team ID in own signature, refusing connection")
            return false
        }
        // Checked by XPC on every message: a client with another signature gets an error.
        connection.setCodeSigningRequirement(clientRequirement)
        let holder = UUID()
        connection.exportedInterface = NSXPCInterface(with: HelperProtocol.self)
        connection.exportedObject = HelperConnection(
            holder: holder, guard: sleepGuard, cleaner: cleaner, version: version,
            onGuardChange: { [weak self] in self?.reevaluate() }
        )
        // Counted before resume, so the matching decrement is always queued after it.
        queue.async { [self] in
            connections += 1
            updateTimers()
        }
        connection.invalidationHandler = { [weak self] in self?.connectionClosed(holder) }
        connection.resume()
        return true
    }

    /// Re-checks both timers; call after anything that may change SleepGuard's state.
    func reevaluate() {
        queue.async { [self] in updateTimers() }
    }

    /// Runs on an XPC queue: the release may block in pmset without holding up the counter.
    private func connectionClosed(_ holder: UUID) {
        do {
            try sleepGuard.release(holder)
        } catch {
            Self.log.error("release \(holder, privacy: .public) on disconnect failed: \(String(describing: error), privacy: .public)")
        }
        queue.async { [self] in
            connections -= 1
            updateTimers()
        }
    }

    // MARK: - Timers (on `queue`)

    private func updateTimers() {
        dispatchPrecondition(condition: .onQueue(queue))
        if sleepGuard.hasPendingReset {
            if retryTimer == nil { startRetryTimer() }
        } else if let timer = retryTimer {
            timer.cancel()
            retryTimer = nil
        }
        if connections == 0, sleepGuard.isIdle {
            if idleTimer == nil { startIdleTimer() }
        } else if let timer = idleTimer {
            timer.cancel()
            idleTimer = nil
        }
    }

    private func startIdleTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.idleExitDelay)
        timer.setEventHandler { [self] in
            // A connection may have arrived (or a reset gone pending) since scheduling.
            guard connections == 0, sleepGuard.isIdle else {
                idleTimer?.cancel()
                idleTimer = nil
                updateTimers()
                return
            }
            Self.log.notice("idle, exiting")
            exit(0)
        }
        idleTimer = timer
        timer.resume()
    }

    private func startRetryTimer() {
        Self.log.notice("disablesleep reset pending, retrying every 15 s")
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.retryInterval, repeating: Self.retryInterval)
        timer.setEventHandler { [self] in
            do {
                try sleepGuard.retryPendingReset()
                if sleepGuard.isIdle { Self.log.notice("pending disablesleep reset done") }
            } catch {
                Self.log.error("pending disablesleep reset failed: \(String(describing: error), privacy: .public)")
            }
            updateTimers()
        }
        retryTimer = timer
        timer.resume()
    }
}
