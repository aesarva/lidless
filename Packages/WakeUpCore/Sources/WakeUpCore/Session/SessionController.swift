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
    @ObservationIgnored private let log = Logger(subsystem: "io.github.alexsarva.WakeUp", category: "session")

    public private(set) var state: SessionState = .off
    public private(set) var attention: SafetyReason?
    public private(set) var startBlock: StartBlock?
    public private(set) var readings: SafetyReadings?
    public var settings: WakeUpSettings {
        didSet { settingsStore.save(settings) }
    }

    public var session: Session? {
        if case .active(let s) = state { return s }
        return nil
    }

    public init(assertions: SleepAssertionService, lid: LidSleepControlling, notifier: Notifier,
                settingsStore: SettingsStore, clock: WakeClock) {
        self.assertions = assertions
        self.lid = lid
        self.notifier = notifier
        self.settingsStore = settingsStore
        self.clock = clock
        self.settings = settingsStore.load()
    }

    // MARK: - Lifecycle

    @discardableResult
    public func start(_ duration: SessionDuration) -> Bool {
        let now = clock.now
        if let r = readings, !SafetyPolicy.canStart(r, settings: settings.safety) {
            startBlock = .lowBattery(threshold: settings.safety.batteryThreshold)
            return false
        }
        do {
            try assertions.acquire(keepDisplayOn: settings.keepDisplayOn)
        } catch {
            log.error("acquire failed: \(String(describing: error))")
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
        if s.lidModeActive {
            do {
                try lid.disable()
            } catch {
                log.error("lid disable failed: \(String(describing: error))")
                attention = .helperUnavailable
                notifier.post(.lidModeSuspended(.helperUnavailable))
            }
        }
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
            try assertions.acquire(keepDisplayOn: on)
            mutateSession { $0.keepDisplayOn = on }
        } catch {
            log.error("re-acquire failed: \(String(describing: error))")
            notifier.post(.assertionFailed(String(describing: error)))
        }
    }

    /// Real behavior is added in Task 6.
    public func setLidMode(_ on: Bool) {
        settings.lidModeEnabled = on
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

    /// Active-session handling is added in Task 6.
    public func update(readings: SafetyReadings) {
        self.readings = readings
        if session == nil {
            startBlock = SafetyPolicy.canStart(readings, settings: settings.safety)
                ? nil : .lowBattery(threshold: settings.safety.batteryThreshold)
        }
    }

    public func clearAttention() {
        attention = nil
    }

    public func recoverAtLaunch() {
        lid.recoverIfNeeded()
        if settings.startSessionOnLaunch {
            start(settings.defaultDuration)
        }
    }

    // MARK: - Private

    private func enableLidMode() {
        do {
            try lid.enable()
            mutateSession {
                $0.lidModeActive = true
                $0.lidModeEnabledAt = clock.now
            }
        } catch {
            log.error("lid enable failed: \(String(describing: error))")
            mutateSession { $0.lidModeActive = false }
        }
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
