import Foundation
import LidlessCore
import os

// Privileged daemon, started by launchd from the plist registered via SMAppService.
// Order matters: a leftover disablesleep 1 is undone, and the 0.2.0 helper removed, before
// any client can connect.

let log = Logger(subsystem: HelperIDs.helper, category: "daemon")
let sleepGuard = SleepGuard(setting: PmsetSleepSetting(), store: FileOwnershipStore())

do {
    try sleepGuard.recoverAtStart()
} catch {
    // Stays pending: the daemon retries it and does not exit while it is pending.
    log.error("recovery at start failed: \(HelperError.message(for: error), privacy: .public)")
}

// The 0.2.0 sudoers helper goes before any client can connect, so no closed-lid hold can be
// in the way. A failure is only logged: the app asks once more, the next start retries.
let cleaner = LegacyHelperCleaner()
if cleaner.isPresent() {
    do {
        let removed = try cleaner.clean()
        log.notice("removed the 0.2.0 helper: \(removed.joined(separator: ", "), privacy: .public)")
    } catch {
        log.error("removing the 0.2.0 helper failed: \(HelperError.message(for: error), privacy: .public)")
    }
}

// launchd sends SIGTERM on unregister, Login Items toggle and shutdown. Every planned exit
// is status 0: the plist's KeepAlive restarts only an unsuccessful one (a crash), whose
// recoverAtStart then resets an owned disablesleep 1 even when no app connects.
signal(SIGTERM, SIG_IGN)
let sigterm = DispatchSource.makeSignalSource(
    signal: SIGTERM, queue: DispatchQueue(label: "io.github.aesarva.Lidless.helper.sigterm"))
sigterm.setEventHandler {
    do {
        // Closes the guard too: an acquire still in flight cannot set 1 before exit.
        try sleepGuard.shutdown()
    } catch {
        log.error("release on SIGTERM failed: \(HelperError.message(for: error), privacy: .public)")
    }
    log.notice("SIGTERM, exiting")
    exit(0)
}
sigterm.resume()

let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
let lifecycle = HelperLifecycle(guard: sleepGuard, scheduler: DispatchHelperScheduler()) {
    exit(0)
}
let daemon = Daemon(guard: sleepGuard, cleaner: cleaner, version: version, lifecycle: lifecycle)
let listener = NSXPCListener(machServiceName: HelperIDs.helper)
listener.delegate = daemon
listener.resume()
lifecycle.reevaluate()
log.notice("listening, version \(version, privacy: .public)")
dispatchMain()
