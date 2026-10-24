import Foundation

/// This app's hold on `disablesleep`, as the helper service last confirmed it.
public struct LidHold: Equatable, Sendable {
    /// The daemon took the hold for this app (its reply came over a connection still open).
    public var held: Bool
    /// The service has not brought the daemon to the wish yet.
    public var pending: Bool
    /// The last error while the wish is not reached.
    public var failure: String?

    public init(held: Bool = false, pending: Bool = false, failure: String? = nil) {
        self.held = held
        self.pending = pending
        self.failure = failure
    }

    /// The failure of an acquisition that was not sent: the helper is not verified
    /// (`.installed`) for this registration yet (also what the backend's refusal says).
    public static let helperNotReady = HelperError.notReady.message
}

@MainActor public protocol LidSleepControlling: AnyObject {
    func helperStatus() -> HelperStatus
    /// The last wish wins: the service brings the daemon to it in order, off the main thread,
    /// and tries again after an error on `retry()`. Publishes `pending` at once.
    func setWanted(_ wanted: Bool)
    /// Called on the main actor whenever the hold changes or a step was answered.
    var onChange: ((LidHold) -> Void)? { get set }
    var hold: LidHold { get }
    /// Tries an unreached wish again (called on each poll of the readings).
    func retry()
    /// A fresh `info`, queued after every command sent so far: true when the daemon answered
    /// that it owns nothing. Not called at all when a new wish came in meanwhile.
    func confirmReleased(_ done: @escaping @MainActor (Bool) -> Void)
    /// Like `confirmReleased`, before the helper is removed: when no daemon can run, true only
    /// if the ownership marker is known to be absent (a daemon that cannot run is no proof).
    func confirmReleasedForRemoval(_ done: @escaping @MainActor (Bool) -> Void)
    /// The daemon connection of `generation` dropped: a hold it carried is gone, and is taken
    /// again while wanted.
    func connectionLost(generation: UInt64)
}

@MainActor public final class LidSleepService: LidSleepControlling {
    /// What the queue and the main actor share, under `shared`'s lock.
    private struct State {
        var wanted = false
        /// Bumped by every `setWanted`: an answer about an older wish is moot.
        var wish: UInt64 = 0
        /// Set while the daemon holds disablesleep for this process: the generation of the
        /// connection that took the hold (the daemon releases it when that connection closes).
        var heldGeneration: UInt64?
        /// The newest connection reported lost. A reply over it or an older one (the enable's
        /// reply racing the report) holds nothing.
        var lostGeneration: UInt64?
        /// A step is queued that has not read the wish yet: another would see the same one.
        var stepQueued = false
    }

    private final class Shared: @unchecked Sendable {
        private let lock = NSLock()
        private var state = State()
        func withLock<T>(_ body: (inout State) -> T) -> T { lock.withLock { body(&state) } }
    }

    private struct StepResult: Sendable {
        let wish: UInt64
        let failure: String?
    }

    private let backend: PrivilegedBackend
    /// Whether the daemon's ownership marker is known to be absent (read on the queue).
    private let markerAbsent: @Sendable () -> Bool
    private let queue = DispatchQueue(label: "io.github.aesarva.Lidless.lid-sleep")
    private let shared = Shared()
    /// Steps queued whose answer has not reached the main actor yet.
    private var outstanding = 0
    public var onChange: ((LidHold) -> Void)?
    public private(set) var hold = LidHold()

    /// `first` runs on the queue before any command (the 0.2.0 reset, which must not race a
    /// new hold). `markerAbsent`: whether the daemon's ownership marker is known to be absent
    /// (`confirmReleasedForRemoval` while no daemon can run).
    public init(backend: PrivilegedBackend,
                markerAbsent: @escaping @Sendable () -> Bool = { FileOwnershipStore().isKnownAbsent() },
                first: (@Sendable () -> Void)? = nil) {
        self.backend = backend
        self.markerAbsent = markerAbsent
        if let first { queue.async(execute: first) }
    }

    public func helperStatus() -> HelperStatus { backend.status() }

    public func setWanted(_ wanted: Bool) {
        let held = shared.withLock { s -> Bool in
            s.wanted = wanted
            s.wish += 1
            return s.heldGeneration != nil
        }
        guard canSend(wanted: wanted, held: held) else {
            publish(LidHold(held: false, pending: false, failure: LidHold.helperNotReady))
            return
        }
        publish(LidHold(held: held, pending: wanted != held))
        enqueueStep()
    }

    /// Nothing is sent, and nothing shows as on its way, while an acquisition could only be
    /// refused: `helperDidChange` retries once the helper is verified.
    public func retry() {
        guard outstanding == 0 else { return }
        let (wanted, held) = shared.withLock { ($0.wanted, $0.heldGeneration != nil) }
        guard hold.failure != nil || wanted != held, canSend(wanted: wanted, held: held) else { return }
        publish(LidHold(held: held, pending: wanted != held))
        enqueueStep()
    }

    public func confirmReleased(_ done: @escaping @MainActor (Bool) -> Void) {
        // No daemon is registered (or allowed to run): nothing holds for this app.
        confirm(withoutDaemon: { true }, done)
    }

    public func confirmReleasedForRemoval(_ done: @escaping @MainActor (Bool) -> Void) {
        // The daemon leaves its marker while disablesleep may still be 1 for it.
        confirm(withoutDaemon: markerAbsent, done)
    }

    /// `withoutDaemon` answers, on the queue, when no daemon is registered or allowed to run.
    private func confirm(withoutDaemon: @escaping @Sendable () -> Bool,
                         _ done: @escaping @MainActor (Bool) -> Void) {
        let wish = shared.withLock { $0.wish }
        queue.async { [weak self, backend] in
            let released: Bool
            switch backend.status() {
            case .notInstalled, .needsApproval, .unsigned:
                released = withoutDaemon()
            case .installed, .checking, .error:
                released = (try? backend.freshInfo()).map { !$0.owned } ?? false
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let (current, wanted) = self.shared.withLock { s -> (Bool, Bool) in
                        guard s.wish == wish else { return (false, s.wanted) }
                        // The wish "no" is reached, whatever the last release said.
                        if released, !s.wanted { s.heldGeneration = nil }
                        return (true, s.wanted)
                    }
                    guard current else { return }
                    if released, !wanted, self.hold != LidHold() { self.publish(LidHold()) }
                    done(released)
                }
            }
        }
    }

    /// Any connection up to the holding one counts: a newer one dropping means the holding
    /// one was already gone.
    public func connectionLost(generation: UInt64) {
        let (ended, wanted) = shared.withLock { s -> (Bool, Bool) in
            s.lostGeneration = max(s.lostGeneration ?? 0, generation)
            guard let holding = s.heldGeneration, generation >= holding else { return (false, s.wanted) }
            s.heldGeneration = nil
            return (true, s.wanted)
        }
        if ended {
            // Without a hold the wish "no" is reached: a failed release is moot.
            let sendable = canSend(wanted: wanted, held: false)
            publish(LidHold(held: false, pending: wanted && sendable,
                            failure: sendable ? nil : LidHold.helperNotReady))
        }
        // Read again: the report may have turned the wish off (a safety suspension). A newer
        // hold is untouched by a late report about an older connection.
        let (stillWanted, held) = shared.withLock { ($0.wanted, $0.heldGeneration != nil) }
        if stillWanted, !held, canSend(wanted: true, held: false) { enqueueStep() }
    }

    // MARK: - Private

    /// An acquisition goes only to a verified helper; a release is always worth a step.
    private func canSend(wanted: Bool, held: Bool) -> Bool {
        !wanted || held || backend.status() == .installed
    }

    private func publish(_ next: LidHold) {
        hold = next
        onChange?(next)
    }

    private func enqueueStep() {
        let queued = shared.withLock { s -> Bool in
            guard !s.stepQueued else { return false }
            s.stepQueued = true
            return true
        }
        guard queued else { return }
        outstanding += 1
        queue.async { [weak self, backend, shared] in
            let result = Self.converge(backend: backend, shared: shared)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.finish(result) }
            }
        }
    }

    /// One step on the queue: reads the wish now and sends what reaches it, if anything.
    private nonisolated static func converge(backend: PrivilegedBackend, shared: Shared) -> StepResult {
        let (wanted, wish, held) = shared.withLock { s -> (Bool, UInt64, Bool) in
            s.stepQueued = false
            return (s.wanted, s.wish, s.heldGeneration != nil)
        }
        let status = backend.status()
        if wanted {
            if held { return StepResult(wish: wish, failure: nil) }
            // Only a daemon verified for this registration is asked to take the hold. The
            // backend checks again as it sends (a re-registration may start in between) and
            // refuses with `HelperError.notReady`, whose message is `helperNotReady`.
            guard status == .installed else { return StepResult(wish: wish, failure: LidHold.helperNotReady) }
            do {
                let generation = try backend.setSleepDisabled(true)
                shared.withLock { s in
                    let lost = s.lostGeneration.map { $0 >= generation } ?? false
                    s.heldGeneration = lost ? nil : generation
                }
                return StepResult(wish: wish, failure: nil)
            } catch {
                return StepResult(wish: wish, failure: HelperError.message(for: error))
            }
        }
        switch status {
        case .notInstalled, .needsApproval, .unsigned:
            // No daemon is registered (or allowed to run): nothing holds for this app.
            shared.withLock { $0.heldGeneration = nil }
            return StepResult(wish: wish, failure: nil)
        case .installed, .checking, .error:
            // Sent even with nothing held here: the daemon may still hold for an earlier
            // request. A successful reply releases this app's hold.
            do {
                try backend.setSleepDisabled(false)
                shared.withLock { $0.heldGeneration = nil }
                return StepResult(wish: wish, failure: nil)
            } catch {
                return StepResult(wish: wish, failure: HelperError.message(for: error))
            }
        }
    }

    private func finish(_ result: StepResult) {
        outstanding -= 1
        let (wanted, wish, held) = shared.withLock { ($0.wanted, $0.wish, $0.heldGeneration != nil) }
        // An answer about an older wish says nothing about the current one: what was
        // published for it stands (a newer step reports its own).
        var failure = result.wish == wish ? result.failure : hold.failure
        var pending = false
        if wanted, held {
            // Held as wished (a step for an older wish took it): a refusal published since is
            // moot. A failed release is kept even with nothing held here: the daemon may hold.
            failure = nil
        } else if wanted != held {
            if outstanding > 0 {
                pending = failure == nil
            } else if failure == nil || (wanted && failure == LidHold.helperNotReady) {
                // The reply came over a connection lost meanwhile, or the helper was verified
                // while a refusal was on its way: again, if anything can be sent.
                if canSend(wanted: wanted, held: held) {
                    failure = nil
                    pending = true
                    enqueueStep()
                } else {
                    failure = LidHold.helperNotReady
                }
            }
        }
        publish(LidHold(held: held, pending: pending, failure: failure))
    }
}
