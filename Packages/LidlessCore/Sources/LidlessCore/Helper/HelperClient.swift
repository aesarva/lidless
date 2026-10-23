import Foundation

public struct HelperInfo: Equatable, Sendable {
    public let version: String
    public let build: String
    public let sleepDisabled: Bool
    /// The daemon set the 1 itself (its marker is `.owned`), so it may reset it.
    public let owned: Bool

    public init(version: String, build: String, sleepDisabled: Bool, owned: Bool) {
        self.version = version
        self.build = build
        self.owned = owned
        self.sleepDisabled = sleepDisabled
    }
}

/// Synchronous calls to the privileged daemon. Errors are `HelperError.rejected` when the
/// daemon dropped the connection unanswered, otherwise `HelperError.commandFailed`.
/// Connections are numbered (generations, increasing from 1): the daemon ties a hold to the
/// connection that took it and releases it when that connection closes.
public protocol HelperClient: AnyObject, Sendable {
    /// Returns the generation of the connection that carried the call.
    @discardableResult func setSleepDisabled(_ disabled: Bool) throws -> UInt64
    func info() throws -> HelperInfo
    /// Returns the removed paths.
    func removeLegacyHelper() throws -> [String]
    /// Called with the generation of a connection after it was dropped (timeout, daemon idle
    /// exit, crash or rejection); the next call opens a new one. A cue to re-check state, not
    /// an error by itself. Delivered asynchronously, so it can arrive after newer calls.
    var onConnectionLost: (@Sendable (UInt64) -> Void)? { get set }
}

/// `HelperClient` over one lazy `NSXPCConnection` to the daemon's Mach service.
public final class XPCHelperClient: HelperClient, @unchecked Sendable {
    private let makeConnection: @Sendable () -> NSXPCConnection
    private let timeout: TimeInterval
    private let lock = NSLock()
    private var connection: NSXPCConnection?
    /// Tells a stale connection's handlers apart from the current connection's.
    private var generation: UInt64 = 0
    private var lostHandler: (@Sendable (UInt64) -> Void)?

    /// `requirement` is the code-signing requirement the daemon must satisfy.
    public convenience init(requirement: String, timeout: TimeInterval = 5) {
        self.init(timeout: timeout) {
            let c = NSXPCConnection(machServiceName: HelperIDs.helper, options: .privileged)
            c.setCodeSigningRequirement(requirement)
            return c
        }
    }

    /// `makeConnection` returns a new, not yet resumed connection to a `HelperProtocol`
    /// service (tests pass an anonymous listener's endpoint).
    public init(timeout: TimeInterval = 5, makeConnection: @escaping @Sendable () -> NSXPCConnection) {
        self.timeout = timeout
        self.makeConnection = makeConnection
    }

    deinit {
        connection?.invalidate()
    }

    public var onConnectionLost: (@Sendable (UInt64) -> Void)? {
        get { lock.withLock { lostHandler } }
        set { lock.withLock { lostHandler = newValue } }
    }

    @discardableResult
    public func setSleepDisabled(_ disabled: Bool) throws -> UInt64 {
        let (error, generation): (String?, UInt64) = try callReportingGeneration { helper, reply in
            helper.setSleepDisabled(disabled) { reply($0) }
        }
        if let error { throw HelperError.commandFailed(error) }
        return generation
    }

    public func info() throws -> HelperInfo {
        let (info, error): (HelperInfo, String?) = try call { helper, reply in
            helper.info { version, build, sleepDisabled, owned, error in
                reply((HelperInfo(version: version, build: build, sleepDisabled: sleepDisabled, owned: owned), error))
            }
        }
        if let error { throw HelperError.commandFailed(error) }
        return info
    }

    public func removeLegacyHelper() throws -> [String] {
        let (removed, error): ([String], String?) = try call { helper, reply in
            helper.removeLegacyHelper { reply(($0, $1)) }
        }
        if let error { throw HelperError.commandFailed(error) }
        return removed
    }

    // MARK: - Connection

    private func currentConnection() -> (NSXPCConnection, UInt64) {
        lock.withLock {
            if let connection { return (connection, generation) }
            generation += 1
            let current = generation
            let c = makeConnection()
            c.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
            // Interruption (the daemon exited) is treated like invalidation: start over next call.
            c.interruptionHandler = { [weak self] in self?.drop(current) }
            c.invalidationHandler = { [weak self] in self?.drop(current) }
            c.resume()
            connection = c
            return (c, current)
        }
    }

    /// Clears the connection of `expected` generation, invalidates it and reports the loss once.
    /// The report is asynchronous: a handler that calls the client again must not hold up
    /// (or nest its own timeout inside) the call that is returning the timeout error.
    private func drop(_ expected: UInt64) {
        let dropped: (NSXPCConnection, (@Sendable (UInt64) -> Void)?)? = lock.withLock {
            guard generation == expected, let c = connection else { return nil }
            connection = nil
            return (c, lostHandler)
        }
        guard let (c, handler) = dropped else { return }
        // Its own invalidation handler then finds a newer (or no) generation and does nothing.
        c.invalidate()
        if let handler { DispatchQueue.global().async { handler(expected) } }
    }

    /// Sends one message and waits up to `timeout` for its reply.
    ///
    /// The synchronous proxy blocks until a reply or an error and has no timeout of its own,
    /// so the message goes out on a background queue and the caller waits on a semaphore
    /// (not a run loop: no re-entrant main-thread work). On timeout the connection is
    /// invalidated, which also releases the blocked background call.
    private func call<T: Sendable>(
        _ send: @escaping @Sendable (HelperProtocol, @escaping @Sendable (T) -> Void) -> Void
    ) throws -> T {
        try callReportingGeneration(send).0
    }

    /// `call` that also returns the generation of the connection that carried it.
    private func callReportingGeneration<T: Sendable>(
        _ send: @escaping @Sendable (HelperProtocol, @escaping @Sendable (T) -> Void) -> Void
    ) throws -> (T, UInt64) {
        let (connection, current) = currentConnection()
        // NSXPCConnection is thread-safe, just not annotated Sendable.
        nonisolated(unsafe) let c = connection
        let outcome = Outcome<T>()
        let done = DispatchSemaphore(value: 0)
        // Reply and error handler may both fire, on any thread: only the first fills the
        // outcome and signals. Signalling before the caller waits is fine (no deadlock).
        let finish: @Sendable (Result<T, HelperError>) -> Void = { result in
            if outcome.fill(result) { done.signal() }
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let proxy = c.synchronousRemoteObjectProxyWithErrorHandler { error in
                // Interrupted or invalid with the call unanswered: a daemon from another build
                // that cannot decode it cancels the connection, which arrives as either.
                let nsError = error as NSError
                let rejected = nsError.domain == NSCocoaErrorDomain
                    && [NSXPCConnectionInterrupted, NSXPCConnectionInvalid].contains(nsError.code)
                let message = error.localizedDescription
                finish(.failure(rejected ? .rejected(message) : .commandFailed(message)))
            }
            guard let helper = proxy as? HelperProtocol else {
                finish(.failure(.commandFailed("unexpected XPC proxy")))
                return
            }
            send(helper) { finish(.success($0)) }
        }
        if done.wait(timeout: .now() + timeout) == .timedOut,
           outcome.fill(.failure(.commandFailed("timed out"))) {
            drop(current)
        }
        guard let result = outcome.result else { throw HelperError.commandFailed("no reply") }
        return (try result.get(), current)
    }
}

/// First-wins slot for a reply that may race its error handler.
private final class Outcome<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Result<T, HelperError>?

    /// Returns false when already filled.
    func fill(_ result: Result<T, HelperError>) -> Bool {
        lock.withLock {
            guard value == nil else { return false }
            value = result
            return true
        }
    }

    var result: Result<T, HelperError>? { lock.withLock { value } }
}
