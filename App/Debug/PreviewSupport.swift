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

@MainActor final class PreviewLid: LidSleepControlling {
    func helperStatus() -> HelperStatus { .installed }
    func enable() throws {}
    func disable() throws {}
    func recoverIfNeeded() -> Bool { true }
    func connectionLost() {}
}

final class PreviewBackend: PrivilegedBackend {
    let current: HelperStatus
    init(_ s: HelperStatus) { current = s }
    func status() -> HelperStatus { current }
    func refreshInfo() {}
    func install() throws {}
    func uninstall() throws {}
    func setSleepDisabled(_ disabled: Bool) throws {}
    func isSleepDisabled() throws -> Bool { false }
    func legacyHelperPresent() -> Bool { false }
    func removeLegacyHelper() throws -> [String] { [] }
    func openSystemSettings() {}
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
    _ c: SessionController, helper: HelperStatus = .installed
) -> some View {
    PopoverView(controller: c, helper: HelperModel(backend: PreviewBackend(helper)), openSettings: { _ in })
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

#Preview("Needs helper") {
    previewView(previewController(readings: previewReadings()), helper: .notInstalled)
}
#endif
