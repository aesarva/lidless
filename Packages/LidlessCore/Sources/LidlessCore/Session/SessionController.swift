import Foundation
import Observation
import os

@MainActor @Observable public final class SessionController {
    private static let endingSoonLead: TimeInterval = 300

    @ObservationIgnored private let assertions: SleepAssertionService
    @ObservationIgnored private let lid: LidSleepControlling
    @ObservationIgnored private let notifier: Notifier
    @ObservationIgnored private let settingsStore: SettingsStore
    @ObservationIgnored private let clock: WakeClock
    @ObservationIgnored private let display: DisplayControlling
    @ObservationIgnored private let log = Logger(subsystem: "io.github.aesarva.Lidless", category: "session")

    @ObservationIgnored private let safetyLog = Logger(subsystem: "io.github.aesarva.Lidless", category: "safety")

    public private(set) var state: SessionState = .off
    public private(set) var attention: SafetyReason?
    public private(set) var startBlock: StartBlock?
    public private(set) var readings: SafetyReadings?
    /// True while off and the most recent lid recovery failed (disablesleep may still be 1).
    @ObservationIgnored private var recoveryPending = false
    /// Lid state from the previous readings, so lid close/open is handled once per edge.
    @ObservationIgnored private var lastLidClosed = false
    /// True while the lid is closed in lid mode and the screen was turned off for it.
    @ObservationIgnored private var displayHeldForLid = false
    public var settings: LidlessSettings {
        didSet { settingsStore.save(settings) }
    }

    public var session: Session? {
        if case .active(let s) = state { return s }
        return nil
    }

    public init(assertions: SleepAssertionService, lid: LidSleepControlling, notifier: Notifier,
                settingsStore: SettingsStore, clock: WakeClock,
                display: DisplayControlling = NoDisplayControl()) {
        self.assertions = assertions
        self.display = display
        self.lid = lid
        self.notifier = notifier
        self.settingsStore = settingsStore
        self.clock = clock
        self.settings = settingsStore.load()
    }

    // MARK: - Lifecycle

    @discardableResult
    public func start(_ duration: SessionDuration) -> Bool {
        guard case .off = state else { return false }
        let now = clock.now
        if let r = readings, !SafetyPolicy.canStart(r, settings: settings.safety) {
            startBlock = .lowBattery(threshold: settings.safety.batteryThreshold)
            return false
        }
        do {
            try assertions.acquire(keepDisplayOn: settings.keepDisplayOn)
        } catch {
            log.error("acquire failed: \(String(describing: error), privacy: .public)")
            notifier.post(.assertionFailed(String(describing: error)))
            return false
        }
        let endsAt = duration.endDate(from: now)
        state = .active(Session(
            startedAt: now,
            endsAt: endsAt,
            keepDisplayOn: settings.keepDisplayOn,
            endingSoonNotified: Self.isWithinWarning(endsAt, now: now)
        ))
        startBlock = nil
        if settings.lidModeEnabled { enableLidMode() }
        return true
    }

    public func stop(_ reason: StopReason) {
        guard case .active(let s) = state else { return }
        assertions.release()
        if s.lidModeActive, !disableLidHandlingFailure() {
            recoveryPending = true
        }
        displayHeldForLid = false
        notifier.cancelEndingSoon()
        switch reason {
        case .timerExpired, .safety: notifier.post(.sessionEnded(reason))
        default: break
        }
        state = .off
    }

    public func restart(_ duration: SessionDuration) {
        guard case .active = state else {
            start(duration)
            return
        }
        let now = clock.now
        let endsAt = duration.endDate(from: now)
        mutateSession {
            $0.startedAt = now
            $0.endsAt = endsAt
            $0.endingSoonNotified = Self.isWithinWarning(endsAt, now: now)
        }
        notifier.cancelEndingSoon()
    }

    public func extend(byMinutes minutes: Int) {
        guard let s = session, let end = s.endsAt else { return }
        let now = clock.now
        let newEnd = max(end, now).addingTimeInterval(TimeInterval(minutes) * 60)
        mutateSession {
            $0.endsAt = newEnd
            $0.endingSoonNotified = Self.isWithinWarning(newEnd, now: now)
        }
        notifier.cancelEndingSoon()
    }

    public func toggle() {
        if session == nil {
            start(settings.defaultDuration)
        } else {
            stop(.user)
        }
    }

    public func setKeepDisplayOn(_ on: Bool) {
        settings.keepDisplayOn = on
        guard session != nil else { return }
        do {
            // With the lid closed in lid mode the screen stays off; the choice applies on open.
            try assertions.acquire(keepDisplayOn: on && !displayHeldForLid)
            mutateSession { $0.keepDisplayOn = on }
        } catch {
            log.error("re-acquire failed: \(String(describing: error), privacy: .public)")
            notifier.post(.assertionFailed(String(describing: error)))
        }
    }

    public func setLidMode(_ on: Bool) {
        settings.lidModeEnabled = on
        guard let s = session else { return }
        if on {
            guard !s.lidModeActive else { return }
            enableLidMode()
        } else {
            if disableLidHandlingFailure() {
                mutateSession {
                    $0.lidModeActive = false
                    $0.lidModeSuspendedReason = nil
                }
            }
        }
    }

    public func tick() {
        guard let s = session, let end = s.endsAt else { return }
        let now = clock.now
        if now >= end {
            stop(.timerExpired)
        } else if !s.endingSoonNotified && end.timeIntervalSince(now) <= Self.endingSoonLead {
            notifier.post(.endingSoon(endsAt: end))
            mutateSession { $0.endingSoonNotified = true }
        }
    }

    public func update(readings: SafetyReadings) {
        // Observation does not compare values: an equal assignment would still redraw the panel.
        if self.readings != readings { self.readings = readings }
        guard let s = session else {
            lastLidClosed = readings.lidClosed
            let block: StartBlock? = SafetyPolicy.canStart(readings, settings: settings.safety)
                ? nil : .lowBattery(threshold: settings.safety.batteryThreshold)
            if startBlock != block { startBlock = block }
            attemptRecovery()
            return
        }
        switch SafetyPolicy.evaluate(readings, session: s, settings: settings.safety) {
        case .none:
            break
        case .stopSession(let r):
            attention = r
            stop(.safety(r))
        case .suspendLidMode(let r):
            if disableLidHandlingFailure() {
                mutateSession {
                    $0.lidModeActive = false
                    $0.lidModeSuspendedReason = r
                }
                attention = r
                notifier.post(.lidModeSuspended(r))
            }
        }
        retryHelperSuspendedLidMode()
        handleLidTransition(closed: readings.lidClosed)
    }

    /// Keeps `.helperUnavailable` while a failed lid recovery is still pending.
    public func clearAttention() {
        attention = recoveryPending ? .helperUnavailable : nil
    }

    /// Undoes a closed-lid mode left behind by an earlier run. Call before the safety engine starts.
    public func recoverAtLaunch() {
        attemptRecovery()
    }

    /// Call after the first safety readings have arrived so the battery rule applies.
    public func startOnLaunchIfEnabled() {
        if settings.startSessionOnLaunch {
            start(settings.defaultDuration)
        }
    }

    /// Call after the helper was installed or removed: retries a pending lid recovery, or
    /// closed-lid mode that is waiting for the helper.
    public func helperDidChange() {
        guard case .off = state else {
            retryHelperSuspendedLidMode()
            return
        }
        attemptRecovery()
    }

    /// Call when the daemon connection of `generation` dropped. If that ended this app's hold
    /// on `disablesleep`, active closed-lid mode is applied again unless the safety rules would
    /// suspend it (then it is suspended for that reason). If re-applying fails, lid mode is
    /// suspended as `.helperUnavailable` and the next readings retry it. A late report about
    /// an older connection (lid mode re-acquired since) is ignored.
    public func helperConnectionLost(generation: UInt64) {
        guard lid.connectionLost(generation: generation) else { return }
        guard let s = session, s.lidModeActive else { return }
        guard settings.lidModeEnabled else {
            // A failed disable left lid mode marked active: the daemon has now done it.
            mutateSession {
                $0.lidModeActive = false
                $0.lidModeSuspendedReason = nil
            }
            recoveryPending = false
            if attention == .helperUnavailable { attention = nil }
            return
        }
        if let reason = safetyBlock(s) {
            suspendLidMode(reason)
        } else if !enableLidMode(keepingStart: true) {
            mutateSession {
                $0.lidModeActive = false
                $0.lidModeSuspendedReason = .helperUnavailable
            }
        }
    }

    // MARK: - Private

    /// Lid closed in lid mode: the Mac keeps running but the screen goes dark (unless an
    /// external display is in use). Lid opened: the display choice applies again.
    private func handleLidTransition(closed: Bool) {
        let wasClosed = lastLidClosed
        lastLidClosed = closed
        guard let s = session else { return }
        if closed, !wasClosed, s.lidModeActive, !display.hasExternalDisplay() {
            if s.keepDisplayOn { _ = reacquire(keepDisplayOn: false) }
            displayHeldForLid = true
            display.sleepDisplayNow()
        } else if !closed, displayHeldForLid {
            displayHeldForLid = false
            if s.keepDisplayOn { _ = reacquire(keepDisplayOn: true) }
        }
    }

    private func reacquire(keepDisplayOn: Bool) -> Bool {
        do {
            try assertions.acquire(keepDisplayOn: keepDisplayOn)
            return true
        } catch {
            log.error("re-acquire failed: \(String(describing: error), privacy: .public)")
            notifier.post(.assertionFailed(String(describing: error)))
            return false
        }
    }

    /// Disables lid mode. On failure the caller's state stays untouched (pmset may still be 1),
    /// `.helperUnavailable` is raised and posted once. Returns true on success.
    private func disableLidHandlingFailure() -> Bool {
        do {
            try lid.disable()
            recoveryPending = false
            return true
        } catch {
            safetyLog.error("lid disable failed: \(String(describing: error), privacy: .public)")
            raiseHelperUnavailable()
            return false
        }
    }

    /// While off: retries undoing a leftover closed-lid mode. On failure raises and posts
    /// `.helperUnavailable` once; on success leaves attention untouched.
    private func attemptRecovery() {
        recoveryPending = !lid.recoverIfNeeded()
        if recoveryPending { raiseHelperUnavailable() }
    }

    private func raiseHelperUnavailable() {
        guard attention != .helperUnavailable else { return }
        attention = .helperUnavailable
        notifier.post(.lidModeSuspended(.helperUnavailable))
    }

    /// `keepingStart`: automatic recovery keeps `lidModeEnabledAt`, so the battery time limit
    /// is not restarted. The user's own enable starts a new interval, even if it fails, so the
    /// automatic retry after it is judged by the new interval.
    @discardableResult
    private func enableLidMode(keepingStart: Bool = false) -> Bool {
        mutateSession {
            if !keepingStart || $0.lidModeEnabledAt == nil { $0.lidModeEnabledAt = clock.now }
        }
        do {
            try lid.enable()
            mutateSession {
                $0.lidModeActive = true
                $0.lidModeSuspendedReason = nil
            }
            return true
        } catch {
            log.error("lid enable failed: \(String(describing: error), privacy: .public)")
            mutateSession {
                if !$0.lidModeActive { $0.lidModeSuspendedReason = .helperUnavailable }
            }
            raiseHelperUnavailable()
            return false
        }
    }

    /// Lid mode the user wants but the helper could not apply: try again, unless the safety
    /// rules would suspend it right away (then it is suspended for that reason instead). A
    /// helper that is not set up cannot answer, so it is not asked until it is
    /// (`helperDidChange`).
    private func retryHelperSuspendedLidMode() {
        guard let s = session, settings.lidModeEnabled, !s.lidModeActive,
              s.lidModeSuspendedReason == .helperUnavailable else { return }
        switch lid.helperStatus() {
        case .installed, .error: break
        case .notInstalled, .needsApproval, .unsigned: return
        }
        if let reason = safetyBlock(s) {
            suspendLidMode(reason)
        } else {
            enableLidMode(keepingStart: true)
        }
    }

    /// Why the safety rules would stop lid mode if it were active now, with its original
    /// start time; nil when they would not (or there are no readings yet).
    private func safetyBlock(_ s: Session) -> SafetyReason? {
        guard let readings else { return nil }
        var enabled = s
        enabled.lidModeActive = true
        enabled.lidModeEnabledAt = s.lidModeEnabledAt ?? clock.now
        switch SafetyPolicy.evaluate(readings, session: enabled, settings: settings.safety) {
        case .none: return nil
        case .suspendLidMode(let r), .stopSession(let r): return r
        }
    }

    /// Suspends lid mode that this app does not hold (nothing to disable), like a safety
    /// suspension: the next readings stop the session if the reason calls for that.
    private func suspendLidMode(_ reason: SafetyReason) {
        mutateSession {
            $0.lidModeActive = false
            $0.lidModeSuspendedReason = reason
        }
        attention = reason
        notifier.post(.lidModeSuspended(reason))
    }

    private func mutateSession(_ body: (inout Session) -> Void) {
        guard case .active(var s) = state else { return }
        body(&s)
        state = .active(s)
    }

    private static func isWithinWarning(_ endsAt: Date?, now: Date) -> Bool {
        endsAt.map { $0.timeIntervalSince(now) <= endingSoonLead } ?? true
    }
}
