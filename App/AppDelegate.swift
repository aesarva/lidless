import AppKit
import WakeUpCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var backend: SudoersBackend!
    private(set) var lid: LidSleepService!
    private(set) var controller: SessionController!
    private(set) var engine: SafetyEngine!
    private var statusItem: StatusItemController!
    private var notifier: UserNotifier!
    private var tickTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let helperDir = Bundle.main.resourceURL!.appending(path: "Helper")
        backend = SudoersBackend(runner: ProcessCommandRunner(), helperDirectory: helperDir, userName: NSUserName())
        lid = LidSleepService(backend: backend)
        notifier = UserNotifier()
        let clock = SystemClock()
        let controller = SessionController(
            assertions: IOPMSleepAssertionService(),
            lid: lid,
            notifier: notifier,
            settingsStore: UserDefaultsSettingsStore(),
            clock: clock
        )
        self.controller = controller
        notifier.onExtend = { [weak controller] minutes in controller?.extend(byMinutes: minutes) }

        engine = SafetyEngine(
            power: IOPowerMonitor(),
            thermal: SystemThermalMonitor(),
            lid: IORegistryLidMonitor(),
            clock: clock,
            onReadings: { [weak controller] readings in controller?.update(readings: readings) }
        )

        statusItem = StatusItemController(
            controller: controller,
            helper: HelperModel(backend: backend),
            openSettings: { _ in /* Task 13 wires SettingsWindowController.show(tab:) */ }
        )
        controller.recoverAtLaunch()
        engine.start()
        statusItem.refresh()

        tickTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.controller.tick()
                self.statusItem.refresh()
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.engine.refresh()
                self?.controller.tick()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if case .active = controller.state { controller.stop(.appQuit) }
    }
}
