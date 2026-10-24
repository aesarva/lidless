import Foundation
import LidlessCore
import os

/// Listener delegate: glue between XPC connections and `HelperLifecycle`.
final class Daemon: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private static let log = Logger(subsystem: HelperIDs.helper, category: "daemon")

    private let sleepGuard: SleepGuard
    private let cleaner: LegacyHelperCleaner
    private let version: String
    private let build: String
    private let lifecycle: HelperLifecycle
    /// nil when the daemon has no Team ID (ad-hoc build): every connection is refused.
    private let clientRequirement = CodeSigningRequirement.requirement(
        identifier: HelperIDs.app, teamID: CodeSigningRequirement.ownTeamID()
    )

    init(guard sleepGuard: SleepGuard, cleaner: LegacyHelperCleaner, version: String, build: String, lifecycle: HelperLifecycle) {
        self.sleepGuard = sleepGuard
        self.cleaner = cleaner
        self.version = version
        self.build = build
        self.lifecycle = lifecycle
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard let clientRequirement else {
            Self.log.error("no Team ID in own signature, refusing connection")
            return false
        }
        // Counted before resume, so the idle exit cannot happen under a live connection.
        guard lifecycle.connectionWillActivate() else {
            Self.log.notice("exiting, refusing connection")
            return false
        }
        // Checked by XPC on every message: a client with another signature gets an error.
        connection.setCodeSigningRequirement(clientRequirement)
        let holder = UUID()
        let lifecycle = lifecycle
        let exported = HelperConnection(
            holder: holder, guard: sleepGuard, cleaner: cleaner, version: version, build: build,
            onGuardChange: { lifecycle.reevaluate() }
        )
        connection.exportedInterface = NSXPCInterface(with: HelperProtocol.self)
        connection.exportedObject = exported
        connection.invalidationHandler = {
            exported.markClosed()
            lifecycle.connectionDidClose(holder: holder)
        }
        connection.resume()
        return true
    }
}
