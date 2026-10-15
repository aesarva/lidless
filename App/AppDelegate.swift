import AppKit
import WakeUpCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var backend: SudoersBackend!
    private(set) var lid: LidSleepService!
    private(set) var controller: SessionController!
    private(set) var engine: SafetyEngine!
    private var statusItem: StatusItemController!
    private var settingsWindow: SettingsWindowController!
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
        notifier.safetySettings = { [weak controller] in controller?.settings.safety ?? SafetySettings() }
        notifier.onExtend = { [weak controller] minutes in controller?.extend(byMinutes: minutes) }

        engine = SafetyEngine(
            power: IOPowerMonitor(),
            thermal: SystemThermalMonitor(),
            lid: IORegistryLidMonitor(),
            clock: clock,
            onReadings: { [weak controller] readings in controller?.update(readings: readings) }
        )

        let helper = HelperModel(backend: backend)
        settingsWindow = SettingsWindowController(controller: controller, helper: helper)
        statusItem = StatusItemController(
            controller: controller,
            helper: helper,
            openSettings: { [weak self] tab in self?.settingsWindow.show(tab: tab) }
        )
        // Order matters: reset a stale lid marker, then take the first readings
        // (engine.start() refreshes immediately), then start-on-launch sees them.
        controller.recoverAtLaunch()
        engine.start()
        controller.startOnLaunchIfEnabled()
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
