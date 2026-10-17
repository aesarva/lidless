import AppKit
import LidlessCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var backend: SudoersBackend!
    private(set) var lid: LidSleepService!
    /// The lid control the controller uses (the real service; a fake in debug review runs).
    private var lidControl: LidSleepControlling!
    private(set) var controller: SessionController!
    private(set) var engine: SafetyEngine!
    private var statusItem: StatusItemController!
    private var settingsWindow: SettingsWindowController!
    private var notifier: UserNotifier!
    private var tickTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        StudioFont.register()
        #if DEBUG
        // Debug args come only from the command line (argument domain), never from persisted defaults.
        let args = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        if let dir = args["SnapshotDir"] as? String {
            SnapshotExporter.export(to: dir)
            NSApp.terminate(nil)
            return
        }
        #endif
        let helperDir = Bundle.main.resourceURL!.appending(path: "Helper")
        backend = SudoersBackend(runner: ProcessCommandRunner(), helperDirectory: helperDir, userName: NSUserName())
        lid = LidSleepService(backend: backend)
        notifier = UserNotifier()
        let clock = SystemClock()
        lidControl = lid
        var settingsStore: SettingsStore = UserDefaultsSettingsStore()
        #if DEBUG
        // Design-review runs never touch the real helper, marker or the user's settings:
        // another Lidless may be running with lid mode on.
        if args["DebugStartSession"] != nil || args["CapturePanelTo"] != nil {
            lidControl = PreviewLid()
            let store = PreviewStore()
            store.settings.lidModeEnabled = true
            settingsStore = store
        }
        #endif
        let controller = SessionController(
            assertions: IOPMSleepAssertionService(),
            lid: lidControl,
            notifier: notifier,
            settingsStore: settingsStore,
            clock: clock,
            display: SystemDisplayControl()
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
        #if DEBUG
        // -DebugStartSession YES -OpenPanelOnLaunch YES: live panel captures for design review.
        if (args["DebugStartSession"] as? String)?.lowercased() == "indefinite" {
            controller.start(.indefinite)
        } else if Self.flag(args["DebugStartSession"]) {
            controller.start(.minutes(60))
        }
        if Self.flag(args["OpenPanelOnLaunch"]) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                MainActor.assumeIsolated { self?.statusItem.openPanel() }
            }
            if let path = args["CapturePanelTo"] as? String {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                    MainActor.assumeIsolated {
                        self?.statusItem.capturePanel(to: URL(fileURLWithPath: path))
                        NSApp.terminate(nil)
                    }
                }
            }
        }
        #endif

        let tick = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.controller.tick()
                self.statusItem.refresh()
            }
        }
        // Common modes: the session must end on time while a menu or an alert is open too.
        RunLoop.main.add(tick, forMode: .common)
        tickTimer = tick
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.engine.refresh()
                self?.controller.tick()
            }
        }
    }

    private static func flag(_ value: Any?) -> Bool {
        switch value {
        case let b as Bool: b
        case let s as String: ["YES", "TRUE", "1"].contains(s.uppercased())
        default: false
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard let controller else { return } // nil when a debug snapshot run quits early
        // Leave the Mac exactly as macOS would have it: the session's assertions go with the
        // process, and closed-lid mode (`pmset disablesleep`) is turned back off here.
        if case .active = controller.state { controller.stop(.appQuit) }
        // A failed earlier reset (orange dot) gets one more try; the watchdog covers the rest.
        _ = lidControl.recoverIfNeeded()
    }
}
