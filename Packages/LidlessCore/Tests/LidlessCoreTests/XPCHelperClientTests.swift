import Foundation
import Testing
@testable import LidlessCore

/// In-process `HelperProtocol` service; `hang` keeps replies pending instead of answering.
private final class TestService: NSObject, HelperProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var _hang = false
    private var _version = "1.0"
    private var pending: [@Sendable () -> Void] = []

    var hang: Bool {
        get { lock.withLock { _hang } }
        set { lock.withLock { _hang = newValue } }
    }

    var version: String {
        get { lock.withLock { _version } }
        set { lock.withLock { _version = newValue } }
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
        answer { reply("pmset failed") }
    }

    func info(reply: @escaping @Sendable (String, Bool) -> Void) {
        let version = self.version
        answer { reply(version, true) }
    }

    func removeLegacyHelper(reply: @escaping @Sendable ([String], String?) -> Void) {
        answer { reply(["/a"], nil) }
    }
}

/// Anonymous listener exporting a `TestService`; counts the connections the client makes.
private final class Harness: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    let service = TestService()
    private let listener = NSXPCListener.anonymous()
    private let lock = NSLock()
    private var made = 0

    var connectionsMade: Int { lock.withLock { made } }

    override init() {
        super.init()
        listener.delegate = self
        listener.resume()
    }

    deinit {
        service.flushPending()
        listener.invalidate()
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: HelperProtocol.self)
        connection.exportedObject = service
        connection.resume()
        return true
    }

    func makeClient(timeout: TimeInterval = 2) -> XPCHelperClient {
        XPCHelperClient(timeout: timeout) { [self] in
            lock.withLock { made += 1 }
            return NSXPCConnection(listenerEndpoint: listener.endpoint)
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

private func elapsed(_ body: () throws -> Void) rethrows -> TimeInterval {
    let start = Date()
    try body()
    return Date().timeIntervalSince(start)
}

@Suite struct XPCHelperClientTests {
    @Test func replyComesBackAsHelperInfo() throws {
        let harness = Harness()
        let client = harness.makeClient()
        #expect(try client.info() == HelperInfo(version: "1.0", sleepDisabled: true))
        #expect(try client.removeLegacyHelper() == ["/a"])
    }

    @Test func errorStringInReplyThrows() {
        let harness = Harness()
        let client = harness.makeClient()
        #expect(throws: HelperError.commandFailed("pmset failed")) {
            try client.setSleepDisabled(true)
        }
    }

    @Test func silentServiceTimesOut() {
        let harness = Harness()
        harness.service.hang = true
        let client = harness.makeClient(timeout: 0.3)
        let time = elapsed {
            #expect(throws: HelperError.commandFailed("timed out")) { try client.info() }
        }
        #expect(time < 1.3)
    }

    @Test func connectionLostFiresOnceAfterTimeout() {
        let harness = Harness()
        harness.service.hang = true
        let client = harness.makeClient(timeout: 0.3)
        let lost = Counter()
        client.onConnectionLost = { lost.increment() }
        #expect(throws: HelperError.commandFailed("timed out")) { try client.info() }
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
        client.onConnectionLost = { [weak client] in
            // Retry once, synchronously, against the still silent service.
            guard lost.increment() == 1 else { return }
            _ = try? client?.info()
            retried.signal()
        }
        let time = elapsed {
            #expect(throws: HelperError.commandFailed("timed out")) { try client.info() }
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
        client.onConnectionLost = { lost.increment() }
        #expect(throws: HelperError.commandFailed("timed out")) { try client.info() }
        #expect(lost.fired.wait(timeout: .now() + 2) == .success)
        harness.service.hang = false
        #expect(try client.info().version == "1.0")
        #expect(harness.connectionsMade == 2)
    }

    @Test func lateReplyAfterTimeoutIsIgnored() throws {
        let harness = Harness()
        harness.service.hang = true
        let client = harness.makeClient(timeout: 0.3)
        #expect(throws: HelperError.commandFailed("timed out")) { try client.info() }
        harness.service.hang = false
        harness.service.version = "2.0"
        harness.service.flushPending() // the old reply ("1.0") arrives late
        #expect(try client.info() == HelperInfo(version: "2.0", sleepDisabled: true))
        #expect(try client.info().version == "2.0")
    }
}
