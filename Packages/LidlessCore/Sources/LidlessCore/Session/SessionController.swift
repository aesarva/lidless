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
    /// True after a release of closed-lid mode failed, until the daemon confirms with a fresh
    /// answer that it holds nothing (disablesleep may still be 1 meanwhile).
    @ObservationIgnored private var recoveryPending = false
    /// The hold this controller last asked the helper service for (`syncLidWanted`).
    @ObservationIgnored private var lidWanted = false
    /// A `confirmReleased` is on its way for the current wish.
    @ObservationIgnored private var confirmInFlight = false
    /// Between `beginHelperRemoval` and `endHelperRemoval`: lid mode is not wanted.
    @ObservationIgnored private var helperRemovalInProgress = false
    /// Lid state from the previous readings, so lid close/open is handled once per edge.
    @ObservationIgnored private var lastLidClosed = false
    /// True while the lid is closed in lid mode and the screen was turned off for it.
    @ObservationIgnored private var displayHeldForLid = false
    public var settings: LidlessSettings {
        didSet { settingsStore.save(settings) }
    }
    /// Asks for a background check of a helper in error (the app's `HelperCoordinator.refresh`),
    /// which calls `helperDidChange` once it is installed again. Called later on the main
    /// actor, never from inside the call that asked, and once for any requests in one turn.
    @ObservationIgnored public var onHelperRefreshNeeded: (() -> Void)?
    @ObservationIgnored private var helperRefreshScheduled = false

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
        lid.onChange = { [weak self] hold in self?.applyLidHold(hold) }
    }

    // MARK: - Lifecycle

    @discardableResult
    public func start(_ duration: SessionDuration) -> Bool {
        let now = clock.now
        guard begin(startedAt: now, endsAt: duration.endDate(from: now),
                    keepDisplayOn: settings.keepDisplayOn) else { return false }
        if settings.lidModeEnabled { enableLidMode() }
        return true
    }

    /// The session on air, for the copy that starts after an update (nil: none is running).
    public func snapshot(now: Date) -> ResumeSnapshot? {
        session.map { ResumeSnapshot(session: $0, savedAt: now) }
    }

    /// Starts the session the previous copy saved before an update relaunched it, like `start`
    /// (low battery stops it). Its ending-soon notice comes again: the previous copy's quit
    /// cancelled it. Lid mode a safety rule suspended stays suspended for that reason (shown
    /// again, not notified again), until the user turns it on again. Any other lid mode, with
    /// the setting on, waits for the helper again, keeping its original start time: it is
    /// wanted only once the safety rules have judged it on readings taken by this copy (now if
    /// there are some, else at the next ones). With the setting off lid mode is off.
    @discardableResult
    public func resume(_ s: ResumeSnapshot) -> Bool {
        guard begin(startedAt: s.startedAt, endsAt: s.endsAt, keepDisplayOn: s.keepDisplayOn) else {
            return false
        }
        if s.endsAt != nil { mutateSession { $0.endingSoonNotified = false } }
        guard settings.lidModeEnabled else { return true }
        if let reason = s.lidModeSuspendedReason, reason != .helperUnavailable {
            mutateSession {
                $0.lidModeEnabledAt = s.lidModeEnabledAt
                $0.lidModeSuspendedReason = reason
            }
            attention = reason
            return true
        }
        // On, on its way, waiting for the helper, or caught between the wish and the service's
        // first answer. Not wanted yet (no `syncLidWanted`): the check below, or the next
        // readings, comes first.
        mutateSession {
            $0.lidModeEnabledAt = s.lidModeEnabledAt
            $0.lidModeSuspendedReason = .helperUnavailable
        }
        if readings != nil {
            suspendBlockedLidWish()
            retryHelperSuspendedLidMode()
            syncLidWanted()
        }
        return true
    }

    /// Call once at launch, after the first safety readings have arrived: resumes the session
    /// saved before an update relaunch if it is still usable, else starts one if the setting
    /// says so.
    public func launch(resuming snapshot: ResumeSnapshot?) {
        if let s = snapshot?.usable(now: clock.now), resume(s) { return }
        startOnLaunchIfEnabled()
    }

    /// Lid mode is released in the background: a release that fails leaves a reset pending.
    public func stop(_ reason: StopReason) {
        guard case .active = state else { return }
        assertions.release()
        displayHeldForLid = false
        notifier.cancelEndingSoon()
        switch reason {
        case .timerExpired, .safety: notifier.post(.sessionEnded(reason))
        default: break
        }
        state = .off
        syncLidWanted()
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

    /// Off is off at once: the helper service releases the hold in the background.
    public func setLidMode(_ on: Bool) {
        settings.lidModeEnabled = on
        guard let s = session else { return }
        if on {
            guard !s.lidModeActive, !s.lidModePending else { return }
            enableLidMode()
        } else {
            mutateSession {
                $0.lidModeActive = false
                $0.lidModePending = false
                $0.lidModeSuspendedReason = nil
            }
            syncLidWanted()
        }
    }

    /// Turns lid mode off before the helper is removed (while the helper can still do it),
    /// then asks the daemon with a fresh answer whether it still owns disablesleep: `done`
    /// gets what to bring back if the removal fails, and whether the helper may be removed
    /// (a hold of this app's own being gone is no proof). Until `endHelperRemoval()` lid mode
    /// is not wanted, so it cannot be taken again meanwhile. Ignored (`done` is not called)
    /// while a removal is already running.
    public func beginHelperRemoval(_ done: @escaping @MainActor (LidModeRestorePoint, Bool) -> Void) {
        guard !helperRemovalInProgress else { return }
        let point = LidModeRestorePoint(
            sessionID: session?.id,
            lidModeEnabled: settings.lidModeEnabled,
            wasActive: session?.lidModeActive ?? false,
            wasPending: session?.lidModePending ?? false,
            suspendedReason: session?.lidModeSuspendedReason
        )
        helperRemovalInProgress = true
        setLidMode(false)
        // A release that failed earlier, with lid mode unwanted already, is sent again.
        lid.retry()
        // Queued after the release; always answered, as the wish cannot change until the end.
        lid.confirmReleasedForRemoval { [weak self] released in
            if released { self?.releaseConfirmed() }
            done(point, released)
        }
    }

    /// Call when the removal is over (after the helper was removed, or after
    /// `restoreAfterFailedRemoval`): lid mode can be wanted again. Restored lid mode is judged
    /// by the safety rules on the latest readings first, as on a poll.
    public func endHelperRemoval() {
        guard helperRemovalInProgress else { return }
        helperRemovalInProgress = false
        suspendBlockedLidWish()
        syncLidWanted()
    }

    /// The helper removal failed: the setting comes back, a safety suspension comes back as
    /// it was, and lid mode that was on, on its way or waiting for the helper waits for the
    /// helper again, keeping its original start time. It is wanted again at
    /// `endHelperRemoval()`, after the safety check.
    /// Only the setting comes back for another session, or when a safety rule suspended lid
    /// mode meanwhile: that suspension stays until the user turns lid mode on again.
    public func restoreAfterFailedRemoval(_ point: LidModeRestorePoint) {
        settings.lidModeEnabled = point.lidModeEnabled
        guard point.lidModeEnabled, let s = session, s.id == point.sessionID,
              !s.lidModeActive else { return }
        if let current = s.lidModeSuspendedReason, current != .helperUnavailable { return }
        if let reason = point.suspendedReason, reason != .helperUnavailable {
            mutateSession { $0.lidModeSuspendedReason = reason }
        } else if point.wasActive || point.wasPending || point.suspendedReason == .helperUnavailable {
            mutateSession { $0.lidModeSuspendedReason = .helperUnavailable }
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
            settleLidHold()
            return
        }
        switch SafetyPolicy.evaluate(readings, session: s, settings: settings.safety) {
        case .none:
            break
        case .stopSession(let r):
            attention = r
            stop(.safety(r))
        case .suspendLidMode(let r):
            suspendLidMode(r)
        }
        suspendBlockedLidWish()
        retryHelperSuspendedLidMode()
        syncLidWanted()
        settleLidHold()
        handleLidTransition(closed: readings.lidClosed)
    }

    /// Keeps `.helperUnavailable` while a failed lid recovery is still pending.
    public func clearAttention() {
        attention = recoveryPending ? .helperUnavailable : nil
    }

    /// Call after the first safety readings have arrived so the battery rule applies.
    public func startOnLaunchIfEnabled() {
        if settings.startSessionOnLaunch {
            start(settings.defaultDuration)
        }
    }

    /// Call after the helper was installed or removed: retries closed-lid mode that is
    /// waiting for the helper, a failed release, or a pending reset.
    public func helperDidChange() {
        retryHelperSuspendedLidMode()
        settleLidHold()
    }

    /// Call when the daemon connection of `generation` dropped. If that ended this app's hold
    /// on `disablesleep`, the helper service takes it again (lid mode shows it on its way),
    /// unless the safety rules would suspend it (then it is suspended for that reason). While
    /// the helper is being re-registered (unregistered, or the replacement not verified yet)
    /// lid mode waits quietly for it; a helper that waits for approval or is in error is
    /// reported once. A late report about an older connection (lid mode re-acquired since)
    /// is ignored.
    public func helperConnectionLost(generation: UInt64) {
        let wasActive = session?.lidModeActive == true
        if wasActive, let s = session, let reason = safetyBlock(s) {
            // The rules would suspend held lid mode now anyway: unwanted before the service
            // hears of the loss, so it never takes the hold again.
            suspendLidMode(reason)
            lid.connectionLost(generation: generation)
            return
        }
        lid.connectionLost(generation: generation)
        guard wasActive, let s = session, !s.lidModeActive else { return }
        let status = lid.helperStatus()
        switch status {
        case .installed:
            return
        case .notInstalled, .checking:
            break
        case .needsApproval, .unsigned, .error:
            raiseHelperUnavailable()
            if case .error = status { requestHelperRefresh() }
        }
        mutateSession { $0.lidModeSuspendedReason = .helperUnavailable }
    }

    // MARK: - Private

    /// What `start` and `resume` share: the low-battery rule, then the assertions.
    private func begin(startedAt: Date, endsAt: Date?, keepDisplayOn: Bool) -> Bool {
        guard case .off = state else { return false }
        if let r = readings, !SafetyPolicy.canStart(r, settings: settings.safety) {
            startBlock = .lowBattery(threshold: settings.safety.batteryThreshold)
            return false
        }
        do {
            try assertions.acquire(keepDisplayOn: keepDisplayOn)
        } catch {
            log.error("acquire failed: \(String(describing: error), privacy: .public)")
            notifier.post(.assertionFailed(String(describing: error)))
            return false
        }
        state = .active(Session(
            startedAt: startedAt,
            endsAt: endsAt,
            keepDisplayOn: keepDisplayOn,
            endingSoonNotified: Self.isWithinWarning(endsAt, now: clock.now)
        ))
        startBlock = nil
        return true
    }

    /// Lid closed in lid mode: the Mac keeps running but the screen goes dark (unless an
    /// external display is in use). Lid opened: the display choice applies again.
    private func handleLidTransition(closed: Bool) {
        let wasClosed = lastLidClosed
        lastLidClosed = closed
        guard let s = session else { return }
        if closed, !wasClosed, s.lidModeActive {
            darkenForClosedLid(s)
        } else if !closed, displayHeldForLid {
            displayHeldForLid = false
            if s.keepDisplayOn { _ = reacquire(keepDisplayOn: true) }
        }
    }

    /// The lid is closed in lid mode: the screen goes dark (unless an external display is in
    /// use), once.
    private func darkenForClosedLid(_ s: Session) {
        guard !displayHeldForLid, !display.hasExternalDisplay() else { return }
        if s.keepDisplayOn { _ = reacquire(keepDisplayOn: false) }
        displayHeldForLid = true
        display.sleepDisplayNow()
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

    /// The only place the wish is set: closed-lid mode is wanted while a session runs with
    /// the setting on, no safety rule suspended it (waiting for the helper still wants it) and
    /// the helper is not being removed. Unwanted, it is off at once; the helper service
    /// releases the hold in the background. Returns whether the wish changed.
    @discardableResult
    private func syncLidWanted() -> Bool {
        var wanted = false
        if let s = session, settings.lidModeEnabled, !helperRemovalInProgress {
            wanted = s.lidModeSuspendedReason == nil || s.lidModeSuspendedReason == .helperUnavailable
        }
        guard wanted != lidWanted else { return false }
        lidWanted = wanted
        // An answer about the previous wish is never delivered.
        confirmInFlight = false
        mutateSession {
            if wanted {
                if $0.lidModeEnabledAt == nil { $0.lidModeEnabledAt = clock.now }
            } else {
                $0.lidModeActive = false
                $0.lidModePending = false
            }
        }
        lid.setWanted(wanted)
        return true
    }

    /// What the helper service confirmed. A hold counts only while it is still wanted.
    private func applyLidHold(_ hold: LidHold) {
        let wanted = lidWanted
        if let s = session {
            let active = hold.held && wanted
            let pending = hold.pending && wanted
            // Observation does not compare values: an equal assignment would still redraw.
            if s.lidModeActive != active || s.lidModePending != pending
                || (active && s.lidModeSuspendedReason != nil) {
                mutateSession {
                    $0.lidModeActive = active
                    $0.lidModePending = pending
                    if active { $0.lidModeSuspendedReason = nil }
                }
            }
            // Held for this app again: a reset pending from an earlier release is moot (a later
            // failed release sets it again).
            if active { recoveryPending = false }
            // Taken with the lid already closed: dark now, not at the next close.
            if active, !s.lidModeActive, readings?.lidClosed == true, let current = session {
                darkenForClosedLid(current)
            }
        }
        guard let failure = hold.failure else { return }
        if wanted {
            lidEnableFailed(failure)
        } else {
            safetyLog.error("lid disable failed: \(failure, privacy: .public)")
            recoveryPending = true
            raiseHelperUnavailable()
        }
    }

    /// Wanted lid mode the helper did not take: it waits as `.helperUnavailable` and the poll
    /// tries again. A refusal because the helper is not verified yet waits quietly, like the
    /// approval (`helperDidChange` brings it); a helper in error, or an error from a verified
    /// one, is reported once.
    private func lidEnableFailed(_ failure: String) {
        mutateSession {
            if !$0.lidModeActive { $0.lidModeSuspendedReason = .helperUnavailable }
        }
        let status = lid.helperStatus()
        if case .error = status {
            raiseHelperUnavailable()
            requestHelperRefresh()
        } else if failure != LidHold.helperNotReady {
            log.error("lid enable failed: \(failure, privacy: .public)")
            raiseHelperUnavailable()
        }
    }

    /// Each poll: an unreached wish is tried again, and a pending reset is confirmed with a
    /// fresh answer from the daemon (only while lid mode is unwanted, whether or not a session
    /// runs).
    private func settleLidHold() {
        lid.retry()
        guard recoveryPending, !lidWanted, !confirmInFlight else { return }
        confirmInFlight = true
        lid.confirmReleased { [weak self] released in
            guard let self else { return }
            confirmInFlight = false
            if released { releaseConfirmed() }
        }
    }

    /// The daemon answered afresh that it owns nothing: a pending reset is done.
    private func releaseConfirmed() {
        guard recoveryPending, !lidWanted else { return }
        recoveryPending = false
        // A safety suspension that still holds shows again.
        if attention == .helperUnavailable {
            let reason = session?.lidModeSuspendedReason
            attention = reason == .helperUnavailable ? nil : reason
        }
    }

    private func raiseHelperUnavailable() {
        guard attention != .helperUnavailable else { return }
        attention = .helperUnavailable
        notifier.post(.lidModeSuspended(.helperUnavailable))
    }

    /// Wants lid mode; the helper service takes the hold in the background. `keepingStart`:
    /// automatic recovery keeps `lidModeEnabledAt`, so the battery time limit is not
    /// restarted. The user's own enable starts a new interval, even if it fails, so the
    /// automatic retry after it is judged by the new interval. Before the helper is set up,
    /// allowed or verified, or in a build that cannot have it, lid mode just waits
    /// (`helperDidChange` turns it on). A helper in error is not asked either, but is always
    /// reported: lid mode the user expects is not on. The safety rules judge the wish first,
    /// on the latest readings: one they would suspend is suspended instead and never wanted.
    private func enableLidMode(keepingStart: Bool = false) {
        mutateSession {
            if !keepingStart || $0.lidModeEnabledAt == nil { $0.lidModeEnabledAt = clock.now }
        }
        if let s = session, let reason = safetyBlock(s) {
            blockLidWish(reason)
            return
        }
        let status = lid.helperStatus()
        switch status {
        case .notInstalled, .needsApproval, .checking, .unsigned, .error:
            // A helper in error is checked again in the background (which re-registers it).
            mutateSession {
                if !$0.lidModeActive { $0.lidModeSuspendedReason = .helperUnavailable }
            }
            if case .error = status {
                raiseHelperUnavailable()
                requestHelperRefresh()
            }
        case .installed:
            mutateSession { $0.lidModeSuspendedReason = nil }
        }
        // Wanted already (waiting for the helper): try again now.
        if !syncLidWanted() { lid.retry() }
    }

    /// Deferred: a refresh may find the helper installed at once and call `helperDidChange`,
    /// which must not run inside `enableLidMode` (it would want lid mode there, and the outer
    /// call would then report a failure over it).
    private func requestHelperRefresh() {
        guard !helperRefreshScheduled else { return }
        helperRefreshScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            helperRefreshScheduled = false
            onHelperRefreshNeeded?()
        }
    }

    /// Lid mode the user wants but the helper could not apply: try again, unless the safety
    /// rules would suspend it right away (then it is suspended for that reason instead, by
    /// `enableLidMode`). A helper that is not set up or verified cannot answer, so it is not
    /// asked until it is (`helperDidChange`); one in error is checked again in the background.
    private func retryHelperSuspendedLidMode() {
        guard let s = session, settings.lidModeEnabled, !s.lidModeActive,
              s.lidModeSuspendedReason == .helperUnavailable else { return }
        switch lid.helperStatus() {
        case .installed, .error: break
        case .notInstalled, .needsApproval, .checking, .unsigned: return
        }
        enableLidMode(keepingStart: true)
    }

    /// An enable the safety rules would suspend at once: suspended, as active lid mode would
    /// be. Already suspended for that reason (the user asked again while it still holds), the
    /// pause shows again without a second notice.
    private func blockLidWish(_ reason: SafetyReason) {
        guard session?.lidModeSuspendedReason != reason else {
            attention = reason
            return
        }
        suspendLidMode(reason)
    }

    /// The safety rules apply to lid mode that is wanted but not held yet (on its way, or
    /// waiting for the helper) as if it were active: it is suspended, and stays so after the
    /// cause goes away, until the user turns it on again.
    private func suspendBlockedLidWish() {
        guard let s = session, settings.lidModeEnabled, !s.lidModeActive,
              s.lidModeSuspendedReason == nil || s.lidModeSuspendedReason == .helperUnavailable,
              let reason = safetyBlock(s) else { return }
        suspendLidMode(reason)
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

    /// Suspends lid mode for a safety reason, held or not: it is unwanted at once (the helper
    /// service releases a hold in the background). The next readings stop the session if the
    /// reason calls for that.
    private func suspendLidMode(_ reason: SafetyReason) {
        mutateSession {
            $0.lidModeActive = false
            $0.lidModePending = false
            $0.lidModeSuspendedReason = reason
        }
        attention = reason
        notifier.post(.lidModeSuspended(reason))
        syncLidWanted()
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
