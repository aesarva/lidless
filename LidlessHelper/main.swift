import Foundation
import LidlessCore
import os

// Privileged daemon, started by launchd from the plist registered via SMAppService.
// Skeleton: only `info` is implemented so far.

final class HelperService: NSObject, HelperProtocol {
    private static let log = Logger(subsystem: HelperIDs.helper, category: "daemon")

    func setSleepDisabled(_ disabled: Bool, reply: @escaping @Sendable (String?) -> Void) {
        reply("not implemented")
    }

    func info(reply: @escaping @Sendable (String, Bool) -> Void) {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        var sleepDisabled = false
        do {
            let result = try ProcessCommandRunner().run("/usr/bin/pmset", ["-g"])
            sleepDisabled = PmsetParser.sleepDisabled(in: result.stdout)
        } catch {
            Self.log.error("pmset -g failed: \(error.localizedDescription, privacy: .public)")
        }
        reply(version, sleepDisabled)
    }

    func removeLegacyHelper(reply: @escaping @Sendable ([String], String?) -> Void) {
        reply([], "not implemented")
    }
}

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    private static let log = Logger(subsystem: HelperIDs.helper, category: "daemon")
    /// nil when the daemon has no Team ID (ad-hoc build): every connection is refused.
    private let clientRequirement = CodeSigningRequirement.requirement(
        identifier: HelperIDs.app, teamID: CodeSigningRequirement.ownTeamID()
    )

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard let clientRequirement else {
            Self.log.error("no Team ID in own signature, refusing connection")
            return false
        }
        // Checked by XPC on every message: a client with another signature gets an error.
        connection.setCodeSigningRequirement(clientRequirement)
        connection.exportedInterface = NSXPCInterface(with: HelperProtocol.self)
        connection.exportedObject = HelperService()
        connection.resume()
        return true
    }
}

let delegate = ListenerDelegate()
let listener = NSXPCListener(machServiceName: HelperIDs.helper)
listener.delegate = delegate
listener.resume()
Logger(subsystem: HelperIDs.helper, category: "daemon").notice("listening")
dispatchMain()
