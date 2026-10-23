import AppKit
import LidlessCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var backend: DaemonBackend!
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
        // Without a Team ID the daemon would refuse the connection: no client, `.unsigned`.
        let client = CodeSigningRequirement
            .requirement(identifier: HelperIDs.helper, teamID: CodeSigningRequirement.ownTeamID())
            .map { XPCHelperClient(requirement: $0) }
        backend = DaemonBackend(registration: SMAppServiceRegistration(), client: client,
                                appVersion: Bundle.main.shortVersion)
        // A 0.2.0 closed-lid session force-quit just before this launch: its watchdog sees this
        // process and never resets, and a daemon not yet approved cannot. In the background:
        // sudo may take a moment, and it only ever writes 0.
        let helperStatus = backend.status()
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let otherCopyRunning = NSRunningApplication.runningApplications(withBundleIdentifier: HelperIDs.app)
            .contains { $0.processIdentifier != ownPID }
        DispatchQueue.global(qos: .utility).async {
            LegacySleepReset().resetIfNeeded(helperStatus: helperStatus, otherCopyRunning: otherCopyRunning)
        }
        lid = LidSleepService(backend: backend)
        notifier = UserNotifier()
        let clock = SystemClock()
        lidControl = lid
        var settingsStore: SettingsStore = UserDefaultsSettingsStore()
        #if DEBUG
        // Design-review runs never turn closed-lid mode on through the real helper or touch the
        // user's settings: another Lidless may be running with lid mode on.
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
        backend.onConnectionLost = { [weak controller] generation in
            Task { @MainActor in controller?.helperConnectionLost(generation: generation) }
        }
        notifier.safetySettings = { [weak controller] in controller?.settings.safety ?? SafetySettings() }
        notifier.onExtend = { [weak controller] minutes in controller?.extend(byMinutes: minutes) }

        engine = SafetyEngine(
            power: IOPowerMonitor(),
            thermal: SystemThermalMonitor(),
            lid: IORegistryLidMonitor(),
            clock: clock,
            onReadings: { [weak controller] readings in controller?.update(readings: readings) }
        )

        let helper = HelperModel(backend: backend, lidModeHeld: { [weak controller] in
            controller?.session?.lidModeActive == true
        })
        // Lid mode the user asked for while the helper waited for approval turns on now.
        helper.onBecameInstalled = { [weak controller] in controller?.helperDidChange() }
        settingsWindow = SettingsWindowController(controller: controller, helper: helper)
        statusItem = StatusItemController(
            controller: controller,
            helper: helper,
            openSettings: { [weak self] tab in self?.settingsWindow.show(tab: tab) }
        )
        // Order matters: undo a leftover lid mode, then take the first readings
        // (engine.start() refreshes immediately), then start-on-launch sees them. The daemon
        // removes a 0.2.0 helper itself when it starts, before any client can connect.
        controller.recoverAtLaunch()
        engine.start()
        controller.startOnLaunchIfEnabled()
        statusItem.refresh()
        // Checks the daemon's version once at launch.
        helper.refresh()
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
        // Back from System Settings: pick up the approval without waiting for the poll.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { helper.refresh() }
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
        // Kept for the protocol; the daemon also lets go when this process's connection closes.
        _ = lidControl.recoverIfNeeded()
    }
}

extension Bundle {
    var shortVersion: String {
        object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    }
}
