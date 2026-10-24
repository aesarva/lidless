import Foundation
import Testing
@testable import LidlessCore

private struct RegisterError: LocalizedError, CustomStringConvertible {
    var errorDescription: String? { "Operation not permitted" }
    var description: String { "Operation not permitted" }
}

private func makeBackend(
    _ status: RegistrationStatus = .enabled, client: HelperClient? = FakeHelperClient(),
    appVersion: String = "0.3.0", appBuild: String = "1",
    root: URL = URL(fileURLWithPath: "/nonexistent-lidless-root")
) -> (DaemonBackend, FakeRegistration) {
    let registration = FakeRegistration(status: status)
    let backend = DaemonBackend(registration: registration, client: client, appVersion: appVersion,
                                appBuild: appBuild,
                                legacy: LegacyHelperCleaner(root: root, runner: FakeCommandRunner()),
                                verifyDelay: 0, unregisterWait: 0, retryDelay: 0)
    return (backend, registration)
}

@Suite struct DaemonBackendTests {
    @Test func statusMapping() {
        #expect(makeBackend(.notRegistered).0.status() == .notInstalled)
        #expect(makeBackend(.requiresApproval).0.status() == .needsApproval)
        // SMAppService may say notFound for a daemon that was never registered.
        #expect(makeBackend(.notFound).0.status() == .notInstalled)
        #expect(makeBackend(.enabled, client: nil).0.status() == .unsigned)
        #expect(makeBackend(.notRegistered, client: nil).0.status() == .unsigned)

        let client = FakeHelperClient()
        let (backend, _) = makeBackend(.enabled, client: client)
        // No XPC from status(): checking until a refresh hears from the daemon.
        #expect(backend.status() == .checking)
        #expect(client.infoCalls == 0)
        backend.refreshInfo()
        #expect(client.infoCalls == 1)
        #expect(backend.status() == .installed)
    }

    @Test func infoFailureIsErrorUntilNextRefresh() {
        let client = FakeHelperClient()
        let (backend, registration) = makeBackend(client: client)
        client.infoError = HelperError.timedOut
        backend.refreshInfo()
        // Re-registered once; the replacement does not answer either.
        #expect(registration.unregisterCalls == 1)
        #expect(registration.registerCalls == 1)
        if case .error(let message) = backend.status() {
            #expect(message.contains("timed out"))
        } else {
            Issue.record("unanswered info() is not .error")
        }
        backend.refreshInfo()
        #expect(registration.registerCalls == 1)
        #expect(backend.status() == .error("timed out"))
        client.infoError = nil
        backend.refreshInfo()
        #expect(backend.status() == .installed)
    }

    /// A daemon that answers with an error (pmset -g failed) is reachable and from this
    /// build: a helper error, not a reason to re-register.
    @Test func errorReplyDoesNotReregister() {
        let client = FakeHelperClient()
        client.infoError = HelperError.commandFailed("pmset failed")
        let (backend, registration) = makeBackend(client: client)
        backend.refreshInfo()
        #expect(backend.status() == .error("pmset failed"))
        #expect(registration.unregisterCalls == 0)
        #expect(registration.registerCalls == 0)
    }

    /// One timeout may be a busy daemon: asked again after `retryDelay` before re-registering.
    @Test func singleTimeoutRetriesBeforeReregistering() {
        let client = FakeHelperClient()
        client.infoScript = [.failure(.timedOut)]
        let (backend, registration) = makeBackend(client: client)
        backend.refreshInfo()
        #expect(client.infoCalls == 2)
        #expect(backend.status() == .installed)
        #expect(registration.calls.isEmpty)
    }

    /// launchd removed a job that kept failing while SMAppService still reports it enabled:
    /// info() only times out until the daemon is registered again.
    @Test func twoTimeoutsReregister() {
        let client = FakeHelperClient()
        client.infoScript = [.failure(.timedOut), .failure(.timedOut)]
        let (backend, registration) = makeBackend(client: client)
        backend.refreshInfo()
        #expect(registration.calls == ["startUnregister", "register"])
        #expect(client.infoCalls == 3)
        #expect(backend.status() == .installed)
    }

    /// A new build without a version change (a dev build, a re-release): its plist and
    /// binary are new, so the daemon is re-registered.
    @Test func buildMismatchReregisters() {
        let client = FakeHelperClient()
        client.infoScript = [.success(HelperInfo(version: "0.3.0", build: "41", sleepDisabled: false, owned: false))]
        client.stubInfo = HelperInfo(version: "0.3.0", build: "42", sleepDisabled: false, owned: false)
        let (backend, registration) = makeBackend(client: client, appVersion: "0.3.0", appBuild: "42")
        backend.refreshInfo()
        #expect(registration.calls == ["startUnregister", "register"])
        #expect(backend.status() == .installed)
    }

    /// `.installed` only once the daemon of the current registration answered with this
    /// app's version and build: not before the first check, nor between a re-registration
    /// and the replacement's answer.
    @Test func statusIsCheckingUntilMatchingInfo() {
        let client = FakeHelperClient()
        let (backend, registration) = makeBackend(client: client)
        #expect(backend.status() == .checking)
        backend.refreshInfo()
        #expect(backend.status() == .installed)

        client.infoScript = [.success(HelperInfo(version: "0.3.0", build: "0", sleepDisabled: false, owned: false))]
        let seen = Statuses()
        client.onInfo = { seen.append(backend.status()) }
        backend.refreshInfo()
        #expect(registration.calls == ["startUnregister", "register"])
        // The old daemon's check, then the replacement's.
        #expect(seen.values == [.installed, .checking])
        #expect(backend.status() == .installed)
    }

    @Test func checkingAfterInstallUntilChecked() throws {
        let (backend, _) = makeBackend(.notRegistered)
        try backend.install()
        #expect(backend.status() == .checking)
        backend.refreshInfo()
        #expect(backend.status() == .installed)
    }

    @Test func lastInfoAfterSuccessfulInfo() {
        let client = FakeHelperClient()
        let info = HelperInfo(version: "0.3.0", build: "1", sleepDisabled: true, owned: true)
        client.stubInfo = info
        let (backend, _) = makeBackend(client: client)
        #expect(backend.lastInfo() == nil)
        backend.refreshInfo()
        #expect(backend.lastInfo() == info)
        // A failed check keeps the last answer: it is for display only.
        client.infoError = HelperError.commandFailed("pmset failed")
        backend.refreshInfo()
        #expect(backend.lastInfo() == info)
    }

    @Test func lastInfoClearedByUninstall() throws {
        let (backend, _) = makeBackend()
        backend.refreshInfo()
        #expect(backend.lastInfo() != nil)
        try backend.uninstall()
        #expect(backend.lastInfo() == nil)
    }

    @Test func lastInfoClearedByInstall() throws {
        let (backend, _) = makeBackend()
        backend.refreshInfo()
        try backend.install()
        #expect(backend.lastInfo() == nil)
    }

    /// No cache: every call asks the daemon; its errors come through as the client threw them.
    @Test func freshInfoAsksTheDaemonEachTime() throws {
        let client = FakeHelperClient()
        let (backend, _) = makeBackend(client: client)
        backend.refreshInfo()
        client.stubInfo = HelperInfo(version: "0.3.0", build: "1", sleepDisabled: true, owned: true)
        #expect(try backend.freshInfo() == client.stubInfo)
        #expect(client.infoCalls == 2)
        client.infoError = HelperError.timedOut
        #expect(throws: HelperError.timedOut) { try backend.freshInfo() }
        client.infoError = HelperError.rejected("connection interrupted")
        #expect(throws: HelperError.rejected("connection interrupted")) { try backend.freshInfo() }
        client.infoError = HelperError.commandFailed("pmset failed")
        #expect(throws: HelperError.commandFailed("pmset failed")) { try backend.freshInfo() }
        #expect(throws: HelperError.commandFailed("closed-lid mode needs a signed build of Lidless")) {
            try makeBackend(client: nil).0.freshInfo()
        }
    }

    /// A matching answer from the old daemon that arrives after the re-registration (another
    /// refresh asked it before) is not about the replacement: still checking.
    @Test func olderCheckDoesNotVerifyTheReplacement() {
        let matching = HelperInfo(version: "0.3.0", build: "1", sleepDisabled: false, owned: false)
        let oldAsked = DispatchSemaphore(value: 0), releaseOld = DispatchSemaphore(value: 0)
        let replacementAsked = DispatchSemaphore(value: 0), releaseReplacement = DispatchSemaphore(value: 0)
        let client = GatedClient { call in
            switch call {
            case 1:
                oldAsked.signal()
                releaseOld.wait()
                return matching
            case 2: throw HelperError.rejected("connection interrupted")
            default:
                replacementAsked.signal()
                releaseReplacement.wait()
                return matching
            }
        }
        let (backend, registration) = makeBackend(client: client)
        let olderDone = DispatchSemaphore(value: 0), reregisteringDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            backend.refreshInfo()
            olderDone.signal()
        }
        oldAsked.wait()
        DispatchQueue.global().async {
            backend.refreshInfo()
            reregisteringDone.signal()
        }
        replacementAsked.wait()
        #expect(registration.calls == ["startUnregister", "register"])
        releaseOld.signal()
        olderDone.wait()
        #expect(backend.status() == .checking)
        releaseReplacement.signal()
        reregisteringDone.wait()
        #expect(backend.status() == .installed)
    }

    /// A check that began before an uninstall + install and fails afterwards (dropped
    /// connection, another version) is about the old daemon: the new one is not re-registered.
    @Test func staleFailureAfterReinstallDoesNotReregister() throws {
        let failures: [Result<HelperInfo, HelperError>] = [
            .failure(.rejected("connection interrupted")),
            .success(HelperInfo(version: "0.2.9", build: "1", sleepDisabled: false, owned: false)),
        ]
        for failure in failures {
            let asked = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
            let client = GatedClient { call in
                guard call == 1 else { return HelperInfo(version: "0.3.0", build: "1", sleepDisabled: false, owned: false) }
                asked.signal()
                release.wait()
                return try failure.get()
            }
            let (backend, registration) = makeBackend(client: client)
            let refreshed = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                backend.refreshInfo()
                refreshed.signal()
            }
            asked.wait()
            try backend.uninstall()
            try backend.install()
            release.signal()
            refreshed.wait()
            #expect(registration.calls == ["unregister", "register"])
            #expect(backend.status() == .checking)
        }
    }

    @Test func refreshInfoDoesNothingUnlessEnabled() {
        let client = FakeHelperClient()
        let (backend, _) = makeBackend(.requiresApproval, client: client)
        backend.refreshInfo()
        #expect(client.infoCalls == 0)
        makeBackend(.enabled, client: nil).0.refreshInfo()
    }

    @Test func installRegistersAndOpensSettingsWhenApprovalNeeded() throws {
        let (backend, registration) = makeBackend(.notRegistered)
        registration.statusAfterRegister = .requiresApproval
        try backend.install()
        #expect(registration.registerCalls == 1)
        #expect(registration.openSettingsCalls == 1)
        #expect(backend.status() == .needsApproval)
    }

    @Test func installThatEnablesDoesNotOpenSettings() throws {
        let (backend, registration) = makeBackend(.notRegistered)
        try backend.install()
        #expect(registration.registerCalls == 1)
        #expect(registration.openSettingsCalls == 0)
        #expect(backend.status() == .checking)
    }

    /// SMAppService.register() throws while the user has not approved the daemon yet.
    @Test func registerErrorWhileAwaitingApprovalOpensSettings() throws {
        let (backend, registration) = makeBackend(.requiresApproval)
        registration.registerError = RegisterError()
        try backend.install()
        #expect(registration.openSettingsCalls == 1)
    }

    @Test func installFailureIsInstallFailed() {
        let (backend, registration) = makeBackend(.notRegistered)
        registration.registerError = RegisterError()
        #expect(throws: HelperError.installFailed("Operation not permitted")) { try backend.install() }
        #expect(registration.openSettingsCalls == 0)
    }

    @Test func uninstallUnregisters() throws {
        let (backend, registration) = makeBackend(.enabled)
        try backend.uninstall()
        #expect(registration.unregisterCalls == 1)
        #expect(backend.status() == .notInstalled)
    }

    /// Nothing registered (a re-registration unregistered it and failed to register again):
    /// Remove has nothing to unregister, and nothing to fail on.
    @Test func uninstallWithNothingRegisteredSucceeds() throws {
        for status in [RegistrationStatus.notRegistered, .notFound] {
            let (backend, registration) = makeBackend(status)
            try backend.uninstall()
            #expect(registration.unregisterCalls == 0)
            #expect(backend.status() == .notInstalled)
        }
    }

    /// Only an enabled registration may have a daemon running, whatever the status says.
    @Test func daemonMayRunFollowsTheRegistration() {
        #expect(makeBackend(.enabled).0.daemonMayRun)
        #expect(!makeBackend(.notRegistered).0.daemonMayRun)
        #expect(!makeBackend(.notFound).0.daemonMayRun)
        #expect(!makeBackend(.requiresApproval).0.daemonMayRun)
        #expect(!makeBackend(.enabled, client: nil).0.daemonMayRun)

        // Unregistered by a re-registration whose register() failed: `.error`, no daemon.
        let client = FakeHelperClient()
        client.stubInfo = HelperInfo(version: "0.2.9", build: "1", sleepDisabled: false, owned: false)
        let (backend, registration) = makeBackend(client: client, appVersion: "0.3.0")
        registration.registerError = RegisterError()
        backend.refreshInfo()
        guard case .error = backend.status() else {
            Issue.record("failed re-registration is not .error")
            return
        }
        #expect(!backend.daemonMayRun)
    }

    @Test func setSleepDisabledPassesThrough() throws {
        let client = FakeHelperClient()
        let (backend, _) = makeBackend(client: client)
        backend.refreshInfo()
        client.generation = 7
        #expect(try backend.setSleepDisabled(true) == 7)
        try backend.setSleepDisabled(false)
        #expect(client.setCalls == [true, false])

        client.stubInfo = HelperInfo(version: "0.3.0", build: "1", sleepDisabled: true, owned: false)
        #expect(try backend.isSleepDisabled() == true)
    }

    @Test func clientErrorBecomesCommandFailed() {
        let client = FakeHelperClient()
        let (backend, _) = makeBackend(client: client)
        backend.refreshInfo()
        client.setError = HelperError.commandFailed("pmset failed")
        #expect(throws: HelperError.commandFailed("pmset failed")) { try backend.setSleepDisabled(true) }
        client.setError = FakeError()
        #expect(throws: HelperError.self) { try backend.setSleepDisabled(true) }
        client.infoError = HelperError.commandFailed("no reply")
        #expect(throws: HelperError.commandFailed("no reply")) { try backend.isSleepDisabled() }
    }

    /// The hold goes only to the daemon verified for this registration; releasing goes to
    /// whatever answers.
    @Test func acquisitionNeedsAVerifiedDaemon() throws {
        let client = FakeHelperClient()
        let (backend, _) = makeBackend(client: client)
        #expect(backend.status() == .checking)
        #expect(throws: HelperError.notReady) { try backend.setSleepDisabled(true) }
        try backend.setSleepDisabled(false)
        #expect(client.setCalls == [false])
        backend.refreshInfo()
        #expect(try backend.setSleepDisabled(true) == 1)
        #expect(client.setCalls == [false, true])
    }

    /// An acquisition that comes in while a re-registration runs waits for it, then finds the
    /// replacement unverified and is refused unsent.
    @Test func acquisitionDuringReregistrationIsRefused() {
        let client = FakeHelperClient()
        let (backend, registration) = makeBackend(client: client)
        backend.refreshInfo()
        #expect(backend.status() == .installed)
        // Another build answers from now on: re-registered, and the replacement never matches.
        client.stubInfo = HelperInfo(version: "0.3.0", build: "2", sleepDisabled: false, owned: false)
        let entered = DispatchSemaphore(value: 0)
        let gate = DispatchSemaphore(value: 0)
        registration.onRegister = {
            entered.signal()
            gate.wait()
        }
        let reregistered = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            backend.refreshInfo()
            reregistered.signal()
        }
        entered.wait()
        let acquired = DispatchSemaphore(value: 0)
        let result = LockedBox<Result<UInt64, Error>?>(nil)
        DispatchQueue.global().async {
            result.value = Result { try backend.setSleepDisabled(true) }
            acquired.signal()
        }
        gate.signal()
        reregistered.wait()
        acquired.wait()
        if case .failure(let error) = result.value {
            #expect(error as? HelperError == .notReady)
        } else {
            Issue.record("acquired from an unverified replacement")
        }
        #expect(client.setCalls.isEmpty)
        #expect(backend.status() != .installed)
    }

    @Test func versionMismatchReregistersOnce() {
        let client = FakeHelperClient()
        client.stubInfo = HelperInfo(version: "0.2.9", build: "1", sleepDisabled: false, owned: false)
        let (backend, registration) = makeBackend(client: client, appVersion: "0.3.0")
        backend.refreshInfo()
        #expect(registration.unregisterCalls == 1)
        #expect(registration.registerCalls == 1)
        // The first info() plus three checks of the replacement.
        #expect(client.infoCalls == 4)
        if case .error = backend.status() {} else { Issue.record("persistent mismatch is not .error") }
        backend.refreshInfo()
        #expect(registration.unregisterCalls == 1)
        #expect(registration.registerCalls == 1)
        if case .error = backend.status() {} else { Issue.record("mismatch after re-registering is not .error") }

        client.stubInfo = HelperInfo(version: "0.3.0", build: "1", sleepDisabled: false, owned: false)
        backend.refreshInfo()
        #expect(backend.status() == .installed)
    }

    /// A daemon from another build can be unable to even decode info(): it drops the
    /// connection. Re-register once, as for a version mismatch.
    @Test func rejectedInfoReregistersOnce() {
        let client = FakeHelperClient()
        client.infoScript = [.failure(.rejected("Couldn’t communicate with a helper application."))]
        let (backend, registration) = makeBackend(client: client, appVersion: "0.3.0")
        backend.refreshInfo()
        #expect(registration.unregisterCalls == 1)
        #expect(registration.registerCalls == 1)
        #expect(client.infoCalls == 2)
        #expect(backend.status() == .installed)

        client.infoScript = [.failure(.rejected("Couldn’t communicate with a helper application."))]
        backend.refreshInfo()
        #expect(registration.registerCalls == 1)
        if case .error = backend.status() {} else { Issue.record("second rejection is not .error") }
    }

    /// register() right after unregister() fails with EPERM while launchd is still removing
    /// the old job: retried after a pause.
    @Test func reregistrationRetriesRegisterWhileLaunchdCatchesUp() {
        let client = FakeHelperClient()
        client.infoScript = [.success(HelperInfo(version: "0.2.9", build: "1", sleepDisabled: false, owned: false))]
        let (backend, registration) = makeBackend(client: client, appVersion: "0.3.0")
        registration.registerError = RegisterError()
        registration.onRegister = { [registration] in
            if registration.registerCalls == 1 { registration.registerError = nil }
        }
        backend.refreshInfo()
        #expect(registration.unregisterCalls == 1)
        #expect(registration.registerCalls == 2)
        #expect(backend.status() == .installed)
    }

    /// register() only after launchd confirmed the old daemon is gone (the completion handler).
    @Test func reregisterWaitsForUnregisterCompletion() {
        let client = FakeHelperClient()
        client.infoScript = [.success(HelperInfo(version: "0.2.9", build: "1", sleepDisabled: false, owned: false))]
        let (backend, registration) = makeBackend(client: client, appVersion: "0.3.0")
        backend.refreshInfo()
        #expect(registration.calls == ["startUnregister", "register"])
        #expect(backend.status() == .installed)
    }

    /// Three register() failures leave the re-registration pending: shown as an error, and
    /// the next refresh registers again, without another unregister.
    @Test func failedReregistrationIsRetriedOnNextRefresh() {
        let client = FakeHelperClient()
        client.stubInfo = HelperInfo(version: "0.2.9", build: "1", sleepDisabled: false, owned: false)
        let (backend, registration) = makeBackend(client: client, appVersion: "0.3.0")
        registration.registerError = RegisterError()
        backend.refreshInfo()
        #expect(registration.registerCalls == 3)
        if case .error(let message) = backend.status() {
            #expect(message.contains("Operation not permitted"))
        } else {
            Issue.record("failed re-registration is not .error")
        }

        registration.registerError = nil
        client.stubInfo = HelperInfo(version: "0.3.0", build: "1", sleepDisabled: false, owned: false)
        backend.refreshInfo()
        #expect(registration.calls == ["startUnregister", "register", "register", "register", "register"])
        #expect(backend.status() == .installed)

        // Done: a later mismatch is not re-registered again in this launch.
        client.stubInfo = HelperInfo(version: "0.2.9", build: "1", sleepDisabled: false, owned: false)
        backend.refreshInfo()
        #expect(registration.registerCalls == 4)
    }

    private func mismatched() -> (DaemonBackend, FakeRegistration, FakeHelperClient) {
        let client = FakeHelperClient()
        client.stubInfo = HelperInfo(version: "0.2.9", build: "1", sleepDisabled: false, owned: false)
        let (backend, registration) = makeBackend(client: client, appVersion: "0.3.0")
        return (backend, registration, client)
    }

    /// register() is not called while launchd has not confirmed the unregister, however
    /// often the status is refreshed; the same outstanding unregister is waited for.
    @Test func registrationBlockedUntilCompletion() {
        let (backend, registration, client) = mismatched()
        registration.unregisterHangs = true
        backend.refreshInfo()
        backend.refreshInfo()
        #expect(registration.calls == ["startUnregister"])
        if case .error(let message) = backend.status() {
            #expect(message.contains("unregister timed out"))
        } else {
            Issue.record("unconfirmed unregister is not .error")
        }
        registration.completeUnregister()
        client.stubInfo = HelperInfo(version: "0.3.0", build: "1", sleepDisabled: false, owned: false)
        backend.refreshInfo()
        #expect(registration.calls == ["startUnregister", "register"])
        #expect(backend.status() == .installed)
    }

    /// The completion that arrives after the wait gave up registers without a second unregister
    /// (which would fail on a job that is already gone).
    @Test func timeoutThenLateSuccessRegistersWithoutSecondUnregister() {
        let (backend, registration, client) = mismatched()
        registration.unregisterHangs = true
        backend.refreshInfo()
        registration.unregisterHangs = false
        registration.completeUnregister()
        client.stubInfo = HelperInfo(version: "0.3.0", build: "1", sleepDisabled: false, owned: false)
        backend.refreshInfo()
        #expect(registration.calls.filter { $0 == "startUnregister" }.count == 1)
        #expect(registration.calls.last == "register")
        #expect(backend.status() == .installed)
    }

    /// The status flipping does not stand for the completion: register() waits for it.
    @Test func statusNotRegisteredWithUnregisterOutstandingDoesNotRegister() throws {
        let (backend, registration, client) = mismatched()
        registration.unregisterHangs = true
        backend.refreshInfo()
        registration.stubStatus = .notRegistered
        backend.refreshInfo()
        #expect(throws: HelperError.self) { try backend.install() }
        #expect(registration.calls == ["startUnregister"])

        registration.completeUnregister(statusFollows: false)
        client.stubInfo = HelperInfo(version: "0.3.0", build: "1", sleepDisabled: false, owned: false)
        backend.refreshInfo()
        #expect(registration.calls == ["startUnregister", "register"])
        #expect(backend.status() == .installed)
    }

    /// The completion arrives while the status still reads enabled: that is confirmation enough.
    @Test func successWhileStillEnabledRegisters() {
        let (backend, registration, client) = mismatched()
        registration.unregisterHangs = true
        backend.refreshInfo()
        registration.completeUnregister(statusFollows: false)
        #expect(registration.stubStatus == .enabled)
        client.stubInfo = HelperInfo(version: "0.3.0", build: "1", sleepDisabled: false, owned: false)
        backend.refreshInfo()
        #expect(registration.calls == ["startUnregister", "register"])
    }

    /// Nothing outstanding (the earlier unregister failed) and launchd no longer has the job:
    /// no new unregister, straight to register().
    @Test func gonePendingRetryWithNothingOutstandingRegisters() {
        let (backend, registration, client) = mismatched()
        registration.unregisterHangs = true
        backend.refreshInfo()
        // The unregister fails while launchd still has the job: this refresh consumes the
        // failed operation, reports it, and registers nothing.
        registration.completeUnregister(error: RegisterError(), statusFollows: false)
        backend.refreshInfo()
        #expect(registration.calls == ["startUnregister"])
        if case .error = backend.status() {} else { Issue.record("failed unregister is not .error") }

        // Nothing outstanding now; the job is gone: register() without another unregister.
        registration.stubStatus = .notRegistered
        client.stubInfo = HelperInfo(version: "0.3.0", build: "1", sleepDisabled: false, owned: false)
        backend.refreshInfo()
        #expect(registration.calls == ["startUnregister", "register"])
        #expect(backend.status() == .installed)
    }

    /// A register() that needs the user's approval ends the re-registration: no retries.
    @Test func reregisterNeedingApprovalIsNotRetried() {
        let (backend, registration, _) = mismatched()
        registration.registerError = RegisterError()
        registration.onRegister = { [registration] in registration.stubStatus = .requiresApproval }
        backend.refreshInfo()
        backend.refreshInfo()
        #expect(registration.registerCalls == 1)
        #expect(backend.status() == .needsApproval)
    }

    /// A failed unregister with the daemon still registered is submitted again.
    @Test func failedUnregisterWithDaemonStillRegisteredStartsANewOne() {
        let (backend, registration, _) = mismatched()
        registration.unregisterHangs = true
        backend.refreshInfo()
        registration.completeUnregister(error: RegisterError())
        registration.unregisterHangs = false
        backend.refreshInfo()
        // The failure is reported; the following refresh submits a new one.
        #expect(registration.calls == ["startUnregister"])
        backend.refreshInfo()
        #expect(registration.calls == ["startUnregister", "startUnregister", "register"])
    }

    /// install() resumes the pending re-registration: it waits for the outstanding unregister.
    @Test func installWaitsForOutstandingUnregister() throws {
        let (backend, registration, _) = mismatched()
        registration.unregisterHangs = true
        backend.refreshInfo()
        #expect(throws: HelperError.self) { try backend.install() }
        #expect(registration.calls == ["startUnregister"])
        registration.completeUnregister()
        try backend.install()
        #expect(registration.calls == ["startUnregister", "register"])
        #expect(backend.status() == .checking)
    }

    /// An explicit register that fails leaves the automatic retry in place.
    @Test func failedInstallKeepsRetry() throws {
        let (backend, registration, client) = mismatched()
        registration.registerError = RegisterError()
        backend.refreshInfo()
        #expect(registration.registerCalls == 3)
        #expect(throws: HelperError.self) { try backend.install() }
        if case .error = backend.status() {} else { Issue.record("failed install lost the error") }
        registration.registerError = nil
        client.stubInfo = HelperInfo(version: "0.3.0", build: "1", sleepDisabled: false, owned: false)
        backend.refreshInfo()
        #expect(backend.status() == .installed)
        #expect(registration.calls.filter { $0 == "startUnregister" }.count == 1)
    }

    /// uninstall() forgets even a finished re-registration: after a new install it may run again.
    @Test func uninstallAllowsReregistrationAgain() throws {
        let (backend, registration, client) = mismatched()
        backend.refreshInfo()
        #expect(registration.unregisterCalls == 1)
        try backend.uninstall()
        try backend.install()
        client.stubInfo = HelperInfo(version: "0.2.9", build: "1", sleepDisabled: false, owned: false)
        backend.refreshInfo()
        #expect(registration.unregisterCalls == 3)
    }

    /// The user's uninstall cancels a pending re-registration.
    @Test func uninstallCancelsPendingReregistration() throws {
        let client = FakeHelperClient()
        client.stubInfo = HelperInfo(version: "0.2.9", build: "1", sleepDisabled: false, owned: false)
        let (backend, registration) = makeBackend(client: client, appVersion: "0.3.0")
        registration.registerError = RegisterError()
        backend.refreshInfo()
        registration.stubStatus = .enabled
        try backend.uninstall()
        registration.registerError = nil
        backend.refreshInfo()
        #expect(registration.registerCalls == 3)
        #expect(backend.status() == .notInstalled)
    }

    @Test func reregistrationVerifiesTheReplacement() {
        let client = FakeHelperClient()
        let old = HelperInfo(version: "0.2.9", build: "1", sleepDisabled: false, owned: false)
        client.infoScript = [.success(old), .failure(.commandFailed("connection interrupted"))]
        let (backend, registration) = makeBackend(client: client, appVersion: "0.3.0")
        backend.refreshInfo()
        #expect(registration.registerCalls == 1)
        #expect(client.infoCalls == 3)
        #expect(backend.status() == .installed)
    }

    @Test func replacementThatNeverAnswersIsError() {
        let client = FakeHelperClient()
        client.infoScript = [.success(HelperInfo(version: "0.2.9", build: "1", sleepDisabled: false, owned: false))]
        client.infoError = HelperError.commandFailed("no reply")
        let (backend, registration) = makeBackend(client: client, appVersion: "0.3.0")
        backend.refreshInfo()
        #expect(registration.registerCalls == 1)
        #expect(client.infoCalls == 4)
        if case .error(let message) = backend.status() {
            #expect(message.contains("no reply"))
        } else {
            Issue.record("unanswered replacement is not .error")
        }
    }

    /// Re-registration paused inside register() while the user uninstalls from another
    /// thread: the uninstall waits for it and wins.
    @Test func uninstallDuringReregistrationWins() {
        let client = FakeHelperClient()
        client.stubInfo = HelperInfo(version: "0.2.9", build: "1", sleepDisabled: false, owned: false)
        let (backend, registration) = makeBackend(client: client, appVersion: "0.3.0")
        let started = DispatchSemaphore(value: 0)
        let gate = DispatchSemaphore(value: 0)
        registration.onRegister = {
            started.signal()
            gate.wait()
        }
        let refreshed = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            backend.refreshInfo()
            refreshed.signal()
        }
        started.wait()
        registration.onRegister = nil
        let uninstalled = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            try? backend.uninstall()
            uninstalled.signal()
        }
        let finishedEarly = uninstalled.wait(timeout: .now() + 0.2) == .success
        #expect(!finishedEarly, "uninstall did not wait for the re-registration")
        gate.signal()
        refreshed.wait()
        if !finishedEarly { uninstalled.wait() }
        #expect(registration.stubStatus == .notRegistered)
        #expect(registration.registerCalls == 1)
        #expect(backend.status() == .notInstalled)
    }

    /// An uninstall between the mismatching info() and the re-registration stops it, even
    /// if launchd still reports the daemon as enabled.
    @Test func uninstallDisablesAutomaticReregistration() {
        let client = FakeHelperClient()
        client.stubInfo = HelperInfo(version: "0.2.9", build: "1", sleepDisabled: false, owned: false)
        let (backend, registration) = makeBackend(client: client, appVersion: "0.3.0")
        client.onInfo = {
            client.onInfo = nil
            try? backend.uninstall()
            registration.stubStatus = .enabled
        }
        backend.refreshInfo()
        #expect(registration.registerCalls == 0)
        #expect(registration.unregisterCalls == 1)

        // An explicit install allows it again.
        try? backend.install()
        #expect(registration.registerCalls == 1)
        backend.refreshInfo()
        #expect(registration.registerCalls == 2)
    }

    /// A verification that began before an uninstall + install must not report on the new
    /// registration.
    @Test func staleVerificationDoesNotOverwriteAfterReinstall() throws {
        let client = FakeHelperClient()
        client.stubInfo = HelperInfo(version: "0.2.9", build: "1", sleepDisabled: false, owned: false)
        let (backend, registration) = makeBackend(client: client, appVersion: "0.3.0")
        let calls = Counter()
        let started = DispatchSemaphore(value: 0)
        let gate = DispatchSemaphore(value: 0)
        client.onInfo = {
            calls.increment()
            // The first check of the replacement pauses.
            if calls.value == 2 {
                started.signal()
                gate.wait()
            }
        }
        let refreshed = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            backend.refreshInfo()
            refreshed.signal()
        }
        started.wait()
        try backend.uninstall()
        try backend.install()
        gate.signal()
        refreshed.wait()
        #expect(registration.stubStatus == .enabled)
        // The stale verification does not count as a check of the new registration.
        #expect(backend.status() == .checking)
        #expect(backend.lastInfo() == nil)
    }

    @Test func unsignedNeverTouchesRegistration() {
        let (backend, registration) = makeBackend(.notRegistered, client: nil)
        if case .installFailed = thrown({ try backend.install() }) {} else {
            Issue.record("install() did not throw installFailed")
        }
        #expect(throws: HelperError.self) { try backend.uninstall() }
        #expect(throws: HelperError.self) { try backend.setSleepDisabled(true) }
        #expect(registration.registerCalls == 0)
        #expect(registration.unregisterCalls == 0)
    }

    @Test func legacyAndConnectionPassThrough() throws {
        let client = FakeHelperClient()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lidless-daemon-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let (backend, registration) = makeBackend(client: client, root: root)
        #expect(!backend.legacyHelperPresent())
        let sudoers = root.appendingPathComponent("etc/sudoers.d")
        try FileManager.default.createDirectory(at: sudoers, withIntermediateDirectories: true)
        try Data().write(to: sudoers.appendingPathComponent("lidless"))
        #expect(backend.legacyHelperPresent())

        client.removeLegacyResult = .success(["/etc/sudoers.d/lidless"])
        #expect(try backend.removeLegacyHelper() == ["/etc/sudoers.d/lidless"])
        client.removeLegacyResult = .failure(.commandFailed("busy: closed-lid mode is active"))
        #expect(throws: HelperError.commandFailed("busy: closed-lid mode is active")) {
            try backend.removeLegacyHelper()
        }

        backend.openSystemSettings()
        #expect(registration.openSettingsCalls == 1)

        let fired = Counter()
        backend.onConnectionLost = { generation in
            if generation == 3 { fired.increment() }
        }
        client.onConnectionLost?(3)
        #expect(fired.value == 1)
    }
}

private func thrown(_ body: () throws -> Void) -> HelperError? {
    do {
        try body()
        return nil
    } catch {
        return error as? HelperError
    }
}

/// `HelperClient` whose `info()` answers come from `answer`, called with the call number
/// (from 1) outside any lock, so a test can hold one call while others go ahead.
private final class GatedClient: HelperClient, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private let answer: @Sendable (Int) throws -> HelperInfo
    var onConnectionLost: (@Sendable (UInt64) -> Void)?

    init(_ answer: @escaping @Sendable (Int) throws -> HelperInfo) { self.answer = answer }

    func setSleepDisabled(_ disabled: Bool) throws -> UInt64 { 1 }
    func info() throws -> HelperInfo {
        let call = lock.withLock { () -> Int in
            calls += 1
            return calls
        }
        return try answer(call)
    }
    func removeLegacyHelper() throws -> [String] { [] }
}

private final class Statuses: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [HelperStatus] = []
    var values: [HelperStatus] { lock.withLock { _values } }
    func append(_ status: HelperStatus) { lock.withLock { _values.append(status) } }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0
    var value: Int { lock.withLock { _value } }
    func increment() { lock.withLock { _value += 1 } }
}

final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ value: T) { _value = value }
    var value: T {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

/// `DaemonBackend` with a re-registration slipped in right after the lid queue's status
/// check said `.installed`, before its acquisition.
private final class ReregisteringAfterStatus: PrivilegedBackend, @unchecked Sendable {
    let inner: DaemonBackend
    private let armed = LockedBox<(@Sendable () -> Void)?>(nil)
    init(_ inner: DaemonBackend) { self.inner = inner }

    func arm(_ reregister: @escaping @Sendable () -> Void) { armed.value = reregister }

    func status() -> HelperStatus {
        let status = inner.status()
        if status == .installed, !Thread.isMainThread, let reregister = armed.value {
            armed.value = nil
            reregister()
        }
        return status
    }
    var daemonMayRun: Bool { inner.daemonMayRun }
    func refreshInfo() { inner.refreshInfo() }
    func lastInfo() -> HelperInfo? { inner.lastInfo() }
    func freshInfo() throws -> HelperInfo { try inner.freshInfo() }
    func install() throws { try inner.install() }
    func uninstall() throws { try inner.uninstall() }
    func setSleepDisabled(_ disabled: Bool) throws -> UInt64 { try inner.setSleepDisabled(disabled) }
    func isSleepDisabled() throws -> Bool { try inner.isSleepDisabled() }
    func legacyHelperPresent() -> Bool { inner.legacyHelperPresent() }
    func removeLegacyHelper() throws -> [String] { try inner.removeLegacyHelper() }
    func openSystemSettings() { inner.openSystemSettings() }
}

@MainActor
struct DaemonBackendLidTests {
    /// The lid service saw a verified daemon, then a re-registration replaced it before the
    /// acquisition: nothing is sent to the unverified replacement, and the service waits for it.
    @Test func reregistrationBetweenStatusAndAcquisitionSendsNothing() async {
        let client = FakeHelperClient()
        let (daemon, _) = makeBackend(client: client)
        daemon.refreshInfo()
        let backend = ReregisteringAfterStatus(daemon)
        backend.arm {
            client.stubInfo = HelperInfo(version: "0.3.0", build: "2", sleepDisabled: false, owned: false)
            daemon.refreshInfo()
        }
        let svc = LidSleepService(backend: backend)
        svc.setWanted(true)
        let deadline = Date().addingTimeInterval(2)
        while svc.hold.failure == nil, Date() < deadline {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        #expect(svc.hold == LidHold(held: false, pending: false, failure: LidHold.helperNotReady))
        #expect(client.setCalls.isEmpty)
        #expect(daemon.status() != .installed)
    }
}
