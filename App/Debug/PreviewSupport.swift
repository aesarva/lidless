#if DEBUG
import SwiftUI
import LidlessCore

// Fakes shared by SwiftUI previews and the -SnapshotDir exporter.

@MainActor final class PreviewAssertions: SleepAssertionService {
    func acquire(keepDisplayOn: Bool) throws {}
    func release() {}
}

@MainActor final class PreviewNotifier: Notifier {
    func post(_ n: WakeNotification) {}
    func cancelEndingSoon() {}
}

@MainActor final class PreviewStore: SettingsStore {
    var settings = LidlessSettings()
    func load() -> LidlessSettings { settings }
    func save(_ s: LidlessSettings) { settings = s }
}

/// Confirms every wish at once.
@MainActor final class PreviewLid: LidSleepControlling {
    var onChange: ((LidHold) -> Void)?
    private(set) var hold = LidHold()
    func helperStatus() -> HelperStatus { .installed }
    func setWanted(_ wanted: Bool) {
        hold = LidHold(held: wanted)
        onChange?(hold)
    }
    func retry() {}
    func confirmReleased(_ done: @escaping @MainActor (Bool) -> Void) { done(true) }
    func confirmReleasedForRemoval(_ done: @escaping @MainActor (Bool) -> Void) { done(true) }
    func connectionLost(generation: UInt64) {}
}

final class PreviewBackend: PrivilegedBackend {
    let current: HelperStatus
    init(_ s: HelperStatus) { current = s }
    func status() -> HelperStatus { current }
    func lastInfo() -> HelperInfo? {
        guard current == .installed else { return nil }
        return HelperInfo(version: Bundle.main.shortVersion, build: Bundle.main.buildVersion,
                          sleepDisabled: false, owned: false)
    }
    func freshInfo() throws -> HelperInfo {
        guard let info = lastInfo() else { throw HelperError.commandFailed("preview") }
        return info
    }
    func refreshInfo() {}
    func install() throws {}
    func uninstall() throws {}
    func setSleepDisabled(_ disabled: Bool) throws -> UInt64 { 0 }
    func isSleepDisabled() throws -> Bool { false }
    func legacyHelperPresent() -> Bool { false }
    func removeLegacyHelper() throws -> [String] { [] }
    func openSystemSettings() {}
}

/// A fixed update state: what the panel, the icon and Settings show, without Sparkle.
@MainActor @Observable final class PreviewUpdates: UpdateSource {
    var state: UpdateState
    var canCheckNow = true
    var automaticallyChecks = true
    let currentVersion = Bundle.main.shortVersion
    let currentBuild = Bundle.main.buildVersion

    init(_ state: UpdateState = .idle) { self.state = state }

    var showsBadge: Bool {
        switch state {
        case .available, .downloading, .installing, .waitingForLid: true
        default: false
        }
    }

    func install() {}
    func checkNow() {}
}

@MainActor func previewController(
    lid: Bool = false, readings: SafetyReadings? = nil
) -> SessionController {
    let store = PreviewStore()
    store.settings.lidModeEnabled = lid
    let c = SessionController(
        assertions: PreviewAssertions(), lid: PreviewLid(), notifier: PreviewNotifier(),
        settingsStore: store, clock: SystemClock()
    )
    if let readings { c.update(readings: readings) }
    return c
}

func previewReadings(battery: Int? = 82, onBattery: Bool = false, thermal: ThermalLevel = .nominal) -> SafetyReadings {
    SafetyReadings(batteryLevel: battery, onBattery: onBattery, thermal: thermal,
                   lidClosed: false, lidClosedOnBatterySince: nil, now: Date())
}

@MainActor func previewView(
    _ c: SessionController, helper: HelperStatus = .installed, updates: UpdateState = .idle
) -> some View {
    PopoverView(controller: c, helper: HelperModel(backend: PreviewBackend(helper)),
                updates: PreviewUpdates(updates), openSettings: { _ in })
}

#Preview("Off") {
    previewView(previewController(readings: previewReadings()))
}

#Preview("Active, indefinite") {
    let c = previewController(readings: previewReadings())
    c.start(.indefinite)
    return previewView(c)
}

#Preview("Active, timer + lid") {
    let c = previewController(lid: true, readings: previewReadings())
    c.start(.minutes(60))
    return previewView(c)
}

#Preview("Start blocked (battery)") {
    let c = previewController(readings: previewReadings(battery: 12, onBattery: true))
    c.start(.indefinite)
    return previewView(c)
}

#Preview("Lid paused (thermal)") {
    let c = previewController(lid: true)
    c.start(.minutes(180))
    c.update(readings: previewReadings(thermal: .serious))
    return previewView(c)
}

#Preview("Helper not set up") {
    previewView(previewController(readings: previewReadings()), helper: .notInstalled)
}

#Preview("Helper needs approval") {
    previewView(previewController(lid: true, readings: previewReadings()), helper: .needsApproval)
}

#Preview("Unsigned build") {
    previewView(previewController(readings: previewReadings()), helper: .unsigned)
}

#Preview("Update available") {
    previewView(previewController(readings: previewReadings()),
                updates: .available(version: "0.4.1", notesURL: URL(string: "https://github.com/aesarva/lidless")))
}

#Preview("Update downloading") {
    previewView(previewController(readings: previewReadings()),
                updates: .downloading(version: "0.4.1", progress: 0.42))
}
#endif
