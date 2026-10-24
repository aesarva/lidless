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
    private(set) var updates: UpdateController!
    private var statusItem: StatusItemController!
    private var settingsWindow: SettingsWindowController!
    private var notifier: UserNotifier!
    private var tickTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        StudioFont.register()
        // Launch args (debug ones, and -UpdateFeedURL in every build) come only from the command
        // line (argument domain), never from persisted defaults.
        let args = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        #if DEBUG
        if let dir = args["SnapshotDir"] as? String {
            SnapshotExporter.export(to: dir)
            Task {
                await SnapshotExporter.exportWindows(to: dir)
                NSApp.terminate(nil)
            }
            return
        }
        #endif
        // Without a Team ID the daemon would refuse the connection: no client, `.unsigned`.
        let client = CodeSigningRequirement
            .requirement(identifier: HelperIDs.helper, teamID: CodeSigningRequirement.ownTeamID())
            .map { XPCHelperClient(requirement: $0) }
        backend = DaemonBackend(registration: SMAppServiceRegistration(), client: client,
                                appVersion: Bundle.main.shortVersion, appBuild: Bundle.main.buildVersion)
        // A 0.2.0 closed-lid session force-quit just before this launch: its watchdog sees this
        // process and never resets, and a daemon not yet approved cannot. First on the lid
        // queue, off the main thread (sudo may take a moment, and it only ever writes 0): lid
        // mode waits for it quietly instead of racing it.
        let helperStatus = backend.status()
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let otherCopyRunning = NSRunningApplication.runningApplications(withBundleIdentifier: HelperIDs.app)
            .contains { $0.processIdentifier != ownPID }
        lid = LidSleepService(backend: backend, first: {
            LegacySleepReset().resetIfNeeded(helperStatus: helperStatus, otherCopyRunning: otherCopyRunning)
        })
        notifier = UserNotifier()
        let clock = SystemClock()
        lidControl = lid
        var settingsStore: SettingsStore = UserDefaultsSettingsStore()
        var resumeStore: ResumeStore? = UserDefaultsResumeStore()
        #if DEBUG
        // Design-review runs never turn closed-lid mode on through the real helper or touch the
        // user's settings: another Lidless may be running with lid mode on.
        if args["DebugStartSession"] != nil || args["CapturePanelTo"] != nil {
            lidControl = PreviewLid()
            let store = PreviewStore()
            store.settings.lidModeEnabled = true
            settingsStore = store
            resumeStore = nil
        }
        #endif
        // The session the previous copy saved before an update relaunched it: read and removed
        // once, before any session can start.
        let resumeSnapshot = resumeStore?.take()
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

        // -UpdateFeedURL works in Release too: Sparkle checks the EdDSA and code signatures anyway.
        // -UpdateOfferLifetime <seconds> shortens the offer for testing; kept within 10 s … 7 days,
        // since 0 would re-check in a loop and a huge value would overflow the sleep.
        let offerLifetime = (args["UpdateOfferLifetime"] as? String).flatMap(Double.init)
            .flatMap { $0.isFinite ? Duration.seconds(min(max($0, 10), 7 * 24 * 60 * 60)) : nil }
        let updates = UpdateController(
            feedOverride: args["UpdateFeedURL"] as? String,
            offerLifetime: offerLifetime ?? .seconds(24 * 60 * 60),
            onShowPanel: { [weak self] in self?.statusItem?.openPanel() },
            lidIsOpen: { [weak controller] in !(controller?.readings?.lidClosed ?? false) },
            // Only the session on air is saved; quitting then ends it as usual (the snapshot
            // brings it back in the new copy).
            onWillRelaunch: { [weak controller] in
                if let s = controller?.snapshot(now: clock.now) { resumeStore?.save(s) }
            }
        )
        self.updates = updates

        engine = SafetyEngine(
            power: IOPowerMonitor(),
            thermal: SystemThermalMonitor(),
            lid: IORegistryLidMonitor(),
            clock: clock,
            onReadings: { [weak controller, weak updates] readings in
                controller?.update(readings: readings)
                // An install held while the lid was closed goes ahead once it opens.
                if !readings.lidClosed { updates?.lidDidOpen() }
            }
        )

        let helper = HelperModel(backend: backend, lidModeHeld: { [weak controller] in
            controller?.session?.lidModeActive == true
        })
        // Lid mode the user asked for while the helper waited for approval turns on now.
        helper.onBecameInstalled = { [weak controller] in controller?.helperDidChange() }
        // Lid mode wanted while the helper is in error: checked again in the background, so the
        // switch never waits for a call that would time out.
        controller.onHelperRefreshNeeded = { [weak helper] in helper?.refresh() }
        settingsWindow = SettingsWindowController(controller: controller, helper: helper, updates: updates)
        statusItem = StatusItemController(
            controller: controller,
            helper: helper,
            updates: updates,
            openSettings: { [weak self] tab in self?.settingsWindow.show(tab: tab) }
        )
        // Order matters: take the first readings (engine.start() refreshes immediately), then
        // the resumed session or start-on-launch sees them. The daemon undoes a leftover hold
        // and removes a 0.2.0 helper itself when it starts, before any client can connect.
        engine.start()
        controller.launch(resuming: resumeSnapshot)
        statusItem.refresh()
        // Checks the daemon's version and build once at launch.
        helper.refresh()
        // After the first readings: an install Sparkle resumes at once needs the lid state.
        updates.start()
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
        // process. Closed-lid mode (`pmset disablesleep`) is released without waiting: the
        // daemon lets go of this app's hold when its connection closes with the process.
        if case .active = controller.state { controller.stop(.appQuit) }
    }
}

extension Bundle {
    var shortVersion: String {
        object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    }

    var buildVersion: String {
        object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
    }
}
