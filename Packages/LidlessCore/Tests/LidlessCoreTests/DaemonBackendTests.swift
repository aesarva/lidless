import Foundation
import Testing
@testable import LidlessCore

private struct RegisterError: LocalizedError {
    var errorDescription: String? { "Operation not permitted" }
}

private func makeBackend(
    _ status: RegistrationStatus = .enabled, client: FakeHelperClient? = FakeHelperClient(),
    appVersion: String = "0.3.0", root: URL = URL(fileURLWithPath: "/nonexistent-lidless-root")
) -> (DaemonBackend, FakeRegistration) {
    let registration = FakeRegistration(status: status)
    let backend = DaemonBackend(registration: registration, client: client, appVersion: appVersion,
                                legacy: LegacyHelperCleaner(root: root, runner: FakeCommandRunner()),
                                verifyDelay: 0)
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
        // No XPC from status(): installed until a refresh says otherwise.
        #expect(backend.status() == .installed)
        #expect(client.infoCalls == 0)
        backend.refreshInfo()
        #expect(client.infoCalls == 1)
        #expect(backend.status() == .installed)
    }

    @Test func infoFailureIsErrorUntilNextRefresh() {
        let client = FakeHelperClient()
        let (backend, _) = makeBackend(client: client)
        client.infoError = HelperError.commandFailed("timed out")
        backend.refreshInfo()
        #expect(backend.status() == .error("timed out"))
        client.infoError = nil
        backend.refreshInfo()
        #expect(backend.status() == .installed)
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
        #expect(backend.status() == .installed)
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

    @Test func setSleepDisabledPassesThrough() throws {
        let client = FakeHelperClient()
        let (backend, _) = makeBackend(client: client)
        client.generation = 7
        #expect(try backend.setSleepDisabled(true) == 7)
        try backend.setSleepDisabled(false)
        #expect(client.setCalls == [true, false])

        client.stubInfo = HelperInfo(version: "0.3.0", sleepDisabled: true)
        #expect(try backend.isSleepDisabled() == true)
    }

    @Test func clientErrorBecomesCommandFailed() {
        let client = FakeHelperClient()
        let (backend, _) = makeBackend(client: client)
        client.setError = HelperError.commandFailed("pmset failed")
        #expect(throws: HelperError.commandFailed("pmset failed")) { try backend.setSleepDisabled(true) }
        client.setError = FakeError()
        #expect(throws: HelperError.self) { try backend.setSleepDisabled(true) }
        client.infoError = HelperError.commandFailed("no reply")
        #expect(throws: HelperError.commandFailed("no reply")) { try backend.isSleepDisabled() }
    }

    @Test func versionMismatchReregistersOnce() {
        let client = FakeHelperClient()
        client.stubInfo = HelperInfo(version: "0.2.9", sleepDisabled: false)
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

        client.stubInfo = HelperInfo(version: "0.3.0", sleepDisabled: false)
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
        client.infoScript = [.success(HelperInfo(version: "0.2.9", sleepDisabled: false))]
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

    @Test func reregistrationGivesUpAfterThreeRegisterFailures() {
        let client = FakeHelperClient()
        client.stubInfo = HelperInfo(version: "0.2.9", sleepDisabled: false)
        let (backend, registration) = makeBackend(client: client, appVersion: "0.3.0")
        registration.registerError = RegisterError()
        backend.refreshInfo()
        #expect(registration.registerCalls == 3)
        // Unregistered and not registered again: the user can install it from the app.
        #expect(backend.status() == .notInstalled)
    }

    @Test func reregistrationVerifiesTheReplacement() {
        let client = FakeHelperClient()
        let old = HelperInfo(version: "0.2.9", sleepDisabled: false)
        client.infoScript = [.success(old), .failure(.commandFailed("connection interrupted"))]
        let (backend, registration) = makeBackend(client: client, appVersion: "0.3.0")
        backend.refreshInfo()
        #expect(registration.registerCalls == 1)
        #expect(client.infoCalls == 3)
        #expect(backend.status() == .installed)
    }

    @Test func replacementThatNeverAnswersIsError() {
        let client = FakeHelperClient()
        client.infoScript = [.success(HelperInfo(version: "0.2.9", sleepDisabled: false))]
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
        client.stubInfo = HelperInfo(version: "0.2.9", sleepDisabled: false)
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
        client.stubInfo = HelperInfo(version: "0.2.9", sleepDisabled: false)
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
        client.stubInfo = HelperInfo(version: "0.2.9", sleepDisabled: false)
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
        #expect(backend.status() == .installed)
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

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0
    var value: Int { lock.withLock { _value } }
    func increment() { lock.withLock { _value += 1 } }
}
