import Foundation

public struct HelperInfo: Equatable, Sendable {
    public let version: String
    public let sleepDisabled: Bool

    public init(version: String, sleepDisabled: Bool) {
        self.version = version
        self.sleepDisabled = sleepDisabled
    }
}

/// Synchronous calls to the privileged daemon. Errors are `HelperError.commandFailed`.
public protocol HelperClient: AnyObject, Sendable {
    func setSleepDisabled(_ disabled: Bool) throws
    func info() throws -> HelperInfo
    /// Returns the removed paths.
    func removeLegacyHelper() throws -> [String]
    /// Called after the connection is dropped (daemon exited, crashed or rejected us);
    /// the next call opens a new one.
    var onConnectionLost: (@Sendable () -> Void)? { get set }
}

/// `HelperClient` over one lazy `NSXPCConnection` to the daemon's Mach service.
public final class XPCHelperClient: HelperClient, @unchecked Sendable {
    private let requirement: String
    private let timeout: TimeInterval
    private let lock = NSLock()
    private var connection: NSXPCConnection?
    /// Tells a stale connection's handlers apart from the current connection's.
    private var generation = 0
    private var lostHandler: (@Sendable () -> Void)?

    /// `requirement` is the code-signing requirement the daemon must satisfy.
    public init(requirement: String, timeout: TimeInterval = 5) {
        self.requirement = requirement
        self.timeout = timeout
    }

    deinit {
        connection?.invalidate()
    }

    public var onConnectionLost: (@Sendable () -> Void)? {
        get { lock.withLock { lostHandler } }
        set { lock.withLock { lostHandler = newValue } }
    }

    public func setSleepDisabled(_ disabled: Bool) throws {
        let error: String? = try call { helper, reply in
            helper.setSleepDisabled(disabled) { reply($0) }
        }
        if let error { throw HelperError.commandFailed(error) }
    }

    public func info() throws -> HelperInfo {
        try call { helper, reply in
            helper.info { version, sleepDisabled in
                reply(HelperInfo(version: version, sleepDisabled: sleepDisabled))
            }
        }
    }

    public func removeLegacyHelper() throws -> [String] {
        let (removed, error): ([String], String?) = try call { helper, reply in
            helper.removeLegacyHelper { reply(($0, $1)) }
        }
        if let error { throw HelperError.commandFailed(error) }
        return removed
    }

    // MARK: - Connection

    private func currentConnection() -> (NSXPCConnection, Int) {
        lock.withLock {
            if let connection { return (connection, generation) }
            generation += 1
            let current = generation
            let c = NSXPCConnection(machServiceName: HelperIDs.helper, options: .privileged)
            c.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
            c.setCodeSigningRequirement(requirement)
            // Interruption (the daemon exited) is treated like invalidation: start over next call.
            c.interruptionHandler = { [weak self] in self?.drop(current) }
            c.invalidationHandler = { [weak self] in self?.drop(current) }
            c.resume()
            connection = c
            return (c, current)
        }
    }

    /// Clears the connection of `expected` generation, invalidates it and reports the loss once.
    private func drop(_ expected: Int) {
        let dropped: (NSXPCConnection, (@Sendable () -> Void)?)? = lock.withLock {
            guard generation == expected, let c = connection else { return nil }
            connection = nil
            return (c, lostHandler)
        }
        guard let (c, handler) = dropped else { return }
        // Its own invalidation handler then finds a newer (or no) generation and does nothing.
        c.invalidate()
        handler?()
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
                finish(.failure(.commandFailed(error.localizedDescription)))
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
        return try result.get()
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
