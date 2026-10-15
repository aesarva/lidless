import SwiftUI
import WakeUpCore

enum SettingsTab { case general, safety, helper, about }

struct PopoverView: View {
    let controller: SessionController
    let helper: HelperModel
    let openSettings: (SettingsTab) -> Void

    var body: some View {
        VStack(spacing: 12) {
            VStack(spacing: 8) {
                MainTile(controller: controller)
                Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                    GridRow {
                        DisplayTile(controller: controller)
                        LidTile(controller: controller, helper: helper)
                    }
                    GridRow {
                        BatteryTile(controller: controller, openSettings: openSettings)
                        ThermalTile(controller: controller, openSettings: openSettings)
                    }
                }
            }
            DurationPills(controller: controller)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                footerButton("gearshape", label: String(localized: "Settings")) { openSettings(.general) }
                Spacer()
                footerButton("power", label: String(localized: "Quit")) { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 300)
    }

    private func footerButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}

#if DEBUG
// MARK: - Preview support

@MainActor private final class PreviewAssertions: SleepAssertionService {
    func acquire(keepDisplayOn: Bool) throws {}
    func release() {}
}

@MainActor private final class PreviewNotifier: Notifier {
    func post(_ n: WakeNotification) {}
    func cancelEndingSoon() {}
}

@MainActor private final class PreviewStore: SettingsStore {
    var settings = WakeUpSettings()
    func load() -> WakeUpSettings { settings }
    func save(_ s: WakeUpSettings) { settings = s }
}

@MainActor private final class PreviewLid: LidSleepControlling {
    func helperStatus() -> HelperStatus { .installed }
    func enable() throws {}
    func disable() throws {}
    func recoverIfNeeded() -> Bool { true }
}

private final class PreviewBackend: PrivilegedBackend {
    let current: HelperStatus
    init(_ s: HelperStatus) { current = s }
    func status() -> HelperStatus { current }
    func install() throws {}
    func uninstall() throws {}
    func setSleepDisabled(_ disabled: Bool) throws {}
    func isSleepDisabled() throws -> Bool { false }
}

@MainActor private func previewController(
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

private func previewReadings(battery: Int? = 82, onBattery: Bool = false, thermal: ThermalLevel = .nominal) -> SafetyReadings {
    SafetyReadings(batteryLevel: battery, onBattery: onBattery, thermal: thermal,
                   lidClosed: false, lidClosedOnBatterySince: nil, now: Date())
}

@MainActor private func previewView(
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
