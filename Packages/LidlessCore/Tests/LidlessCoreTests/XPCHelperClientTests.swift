import Foundation
import Testing
@testable import LidlessCore

/// In-process `HelperProtocol` service; `hang` keeps replies pending instead of answering.
private final class TestService: NSObject, HelperProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var _hang = false
    private var _version = "1.0"
    private var _infoError: String?
    private var _setError: String? = "pmset failed"
    private var pending: [@Sendable () -> Void] = []

    var hang: Bool {
        get { lock.withLock { _hang } }
        set { lock.withLock { _hang = newValue } }
    }

    var version: String {
        get { lock.withLock { _version } }
        set { lock.withLock { _version = newValue } }
    }

    var infoError: String? {
        get { lock.withLock { _infoError } }
        set { lock.withLock { _infoError = newValue } }
    }

    var setError: String? {
        get { lock.withLock { _setError } }
        set { lock.withLock { _setError = newValue } }
    }

    /// Answers every reply held back while hanging (a late reply).
    func flushPending() {
        let replies = lock.withLock { () -> [@Sendable () -> Void] in
            defer { pending = [] }
            return pending
        }
        replies.forEach { $0() }
    }

    private func answer(_ reply: @escaping @Sendable () -> Void) {
        let held = lock.withLock { () -> Bool in
            if _hang { pending.append(reply) }
            return _hang
        }
        if !held { reply() }
    }

    func setSleepDisabled(_ disabled: Bool, reply: @escaping @Sendable (String?) -> Void) {
        let error = self.setError
        answer { reply(error) }
    }

    func info(reply: @escaping @Sendable (String, String, Bool, Bool, String?) -> Void) {
        let (version, error) = (self.version, self.infoError)
        answer { reply(version, "7", true, false, error) }
    }

    func removeLegacyHelper(reply: @escaping @Sendable ([String], String?) -> Void) {
        answer { reply(["/a"], nil) }
    }
}

/// The interface of an older daemon: same selector, a reply block with another signature.
@objc private protocol OldHelperProtocol {
    func info(reply: @escaping @Sendable (String) -> Void)
}

private final class OldService: NSObject, OldHelperProtocol {
    func info(reply: @escaping @Sendable (String) -> Void) { reply("0.2.0") }
}

/// What the listener does with a new connection.
private enum Serving {
    case current
    /// Exports `OldHelperProtocol`: a daemon left over from an older build.
    case old
    /// Refuses the connection, as a daemon does when the code-signing check fails.
    case refuse
}

/// Anonymous listener exporting a `TestService`; counts the connections the client makes.
private final class Harness: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    let service = TestService()
    private let serving: Serving
    private let listener = NSXPCListener.anonymous()
    private let lock = NSLock()
    private var made = 0
    private var accepted: [NSXPCConnection] = []

    var connectionsMade: Int { lock.withLock { made } }

    /// Drops every accepted connection from the service side, as a daemon exit would.
    func invalidateServerConnections() {
        let connections = lock.withLock { () -> [NSXPCConnection] in
            defer { accepted = [] }
            return accepted
        }
        connections.forEach { $0.invalidate() }
    }

    init(serving: Serving = .current) {
        self.serving = serving
        super.init()
        listener.delegate = self
        listener.resume()
    }

    deinit {
        service.flushPending()
        listener.invalidate()
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        switch serving {
        case .refuse:
            return false
        case .old:
            connection.exportedInterface = NSXPCInterface(with: OldHelperProtocol.self)
            connection.exportedObject = OldService()
        case .current:
            connection.exportedInterface = NSXPCInterface(with: HelperProtocol.self)
            connection.exportedObject = service
        }
        lock.withLock { accepted.append(connection) }
        connection.resume()
        return true
    }

    /// `requirementForFirst`: a code-signing requirement set on the first connection only.
    func makeClient(timeout: TimeInterval = 2, requirementForFirst: String? = nil) -> XPCHelperClient {
        XPCHelperClient(timeout: timeout) { [self] in
            let n = lock.withLock { made += 1; return made }
            let c = NSXPCConnection(listenerEndpoint: listener.endpoint)
            if n == 1, let requirementForFirst { c.setCodeSigningRequirement(requirementForFirst) }
            return c
        }
    }
}

/// Thread-safe counter for callbacks fired on XPC or global queues.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    let fired = DispatchSemaphore(value: 0)

    var value: Int { lock.withLock { n } }

    /// Returns the new count.
    @discardableResult
    func increment() -> Int {
        let v = lock.withLock { n += 1; return n }
        fired.signal()
        return v
    }
}

private final class LockedValue<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ value: T) { _value = value }
    var value: T {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

private func elapsed(_ body: () throws -> Void) rethrows -> TimeInterval {
    let start = Date()
    try body()
    return Date().timeIntervalSince(start)
}

@Suite struct XPCHelperClientTests {
    @Test func infoDecodesBuildAndOwned() throws {
        let client = Harness().makeClient()
        let info = try client.info()
        #expect(info.build == "7")
        #expect(!info.owned)
    }

    /// A daemon whose bundle was replaced while it runs (an update) no longer satisfies the
    /// client's code-signing requirement. Re-registration starts the new one: `.rejected`,
    /// the failed connection is reported lost, and the same client reaches the replacement.
    @Test func daemonFailingTheSignatureRequirementIsRejected() throws {
        let harness = Harness()
        let client = harness.makeClient(requirementForFirst: #"identifier "io.github.aesarva.Lidless.nobody""#)
        let lost = LockedValue<[UInt64]>([])
        let counter = Counter()
        client.onConnectionLost = { generation in
            lost.value.append(generation)
            counter.increment()
        }
        #expect {
            try client.info()
        } throws: { error in
            if case .rejected = error as? HelperError { return true }
            return false
        }
        #expect(counter.fired.wait(timeout: .now() + 2) == .success)
        #expect(lost.value == [1])
        #expect(try client.info().version == "1.0")
        #expect(harness.connectionsMade == 2)
    }

    @Test func replyComesBackAsHelperInfo() throws {
        let harness = Harness()
        let client = harness.makeClient()
        #expect(try client.info() == HelperInfo(version: "1.0", build: "7", sleepDisabled: true, owned: false))
        #expect(try client.removeLegacyHelper() == ["/a"])
    }

    /// A daemon from another build cannot decode the call and drops the connection: that
    /// is `.rejected`, which the backend logs as a dropped connection.
    @Test func olderDaemonInterfaceIsRejected() {
        let harness = Harness(serving: .old)
        let client = harness.makeClient()
        #expect {
            try client.info()
        } throws: { error in
            if case .rejected = error as? HelperError { return true }
            return false
        }
    }

    @Test func refusedConnectionIsRejected() {
        let harness = Harness(serving: .refuse)
        let client = harness.makeClient()
        #expect {
            try client.info()
        } throws: { error in
            if case .rejected = error as? HelperError { return true }
            return false
        }
    }

    @Test func errorStringInReplyThrows() {
        let harness = Harness()
        let client = harness.makeClient()
        #expect(throws: HelperError.commandFailed("pmset failed")) {
            try client.setSleepDisabled(true)
        }
    }

    @Test func errorInInfoReplyThrows() {
        let harness = Harness()
        harness.service.infoError = "pmset -g failed"
        let client = harness.makeClient()
        #expect(throws: HelperError.commandFailed("pmset -g failed")) { try client.info() }
    }

    /// No reply within the timeout is `.timedOut`, not a reply with an error: the backend
    /// re-registers after two in a row, never after an error reply.
    @Test func timeoutThrowsTimedOut() {
        let harness = Harness()
        harness.service.hang = true
        let client = harness.makeClient(timeout: 0.3)
        let time = elapsed {
            #expect(throws: HelperError.timedOut) { try client.info() }
        }
        #expect(time < 1.3)
    }

    @Test func connectionLostFiresOnceAfterTimeout() {
        let harness = Harness()
        harness.service.hang = true
        let client = harness.makeClient(timeout: 0.3)
        let lost = Counter()
        client.onConnectionLost = { _ in lost.increment() }
        #expect(throws: HelperError.timedOut) { try client.info() }
        #expect(lost.fired.wait(timeout: .now() + 2) == .success)
        // The invalidated connection's own handler runs too; it must not report again.
        Thread.sleep(forTimeInterval: 0.2)
        #expect(lost.value == 1)
    }

    @Test func retryFromConnectionLostDoesNotBlockTheTimedOutCall() {
        let harness = Harness()
        harness.service.hang = true
        let client = harness.makeClient(timeout: 0.5)
        let lost = Counter()
        let retried = DispatchSemaphore(value: 0)
        client.onConnectionLost = { [weak client] _ in
            // Retry once, synchronously, against the still silent service.
            guard lost.increment() == 1 else { return }
            _ = try? client?.info()
            retried.signal()
        }
        let time = elapsed {
            #expect(throws: HelperError.timedOut) { try client.info() }
        }
        // A synchronous callback would add the retry's own 0.5 s timeout.
        #expect(time < 0.9)
        #expect(retried.wait(timeout: .now() + 2) == .success)
    }

    @Test func reconnectsAfterLostConnection() throws {
        let harness = Harness()
        harness.service.hang = true
        let client = harness.makeClient(timeout: 0.3)
        let lost = Counter()
        client.onConnectionLost = { _ in lost.increment() }
        #expect(throws: HelperError.timedOut) { try client.info() }
        #expect(lost.fired.wait(timeout: .now() + 2) == .success)
        harness.service.hang = false
        #expect(try client.info().version == "1.0")
        #expect(harness.connectionsMade == 2)
    }

    @Test func serverSideLossIsReportedOnceAndReconnects() throws {
        let harness = Harness()
        let client = harness.makeClient()
        let lost = Counter()
        client.onConnectionLost = { _ in lost.increment() }
        #expect(try client.info().version == "1.0")
        // The client is idle: only its XPC handlers can notice (XPC reports an interruption).
        harness.invalidateServerConnections()
        #expect(lost.fired.wait(timeout: .now() + 2) == .success)
        Thread.sleep(forTimeInterval: 0.2)
        #expect(lost.value == 1)
        #expect(try client.info().version == "1.0")
        #expect(harness.connectionsMade == 2)
    }

    /// The loss names the connection it ended, and each call says which connection served it.
    @Test func lossCarriesTheGenerationThatServedTheCall() throws {
        let harness = Harness()
        harness.service.setError = nil
        let client = harness.makeClient()
        let lostGeneration = LockedValue<UInt64?>(nil)
        let lost = Counter()
        client.onConnectionLost = { generation in
            lostGeneration.value = generation
            lost.increment()
        }
        let first = try client.setSleepDisabled(true)
        harness.invalidateServerConnections()
        #expect(lost.fired.wait(timeout: .now() + 2) == .success)
        #expect(lostGeneration.value == first)
        let second = try client.setSleepDisabled(true)
        #expect(second > first)
    }

    @Test func lateReplyAfterTimeoutIsIgnored() throws {
        let harness = Harness()
        harness.service.hang = true
        let client = harness.makeClient(timeout: 0.3)
        #expect(throws: HelperError.timedOut) { try client.info() }
        harness.service.hang = false
        harness.service.version = "2.0"
        harness.service.flushPending() // the old reply ("1.0") arrives late
        #expect(try client.info() == HelperInfo(version: "2.0", build: "7", sleepDisabled: true, owned: false))
        #expect(try client.info().version == "2.0")
    }
}
