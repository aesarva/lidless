import Foundation
import LidlessCore
import Observation
import OSLog
import Sparkle

/// Owns the Sparkle updater and publishes the update state for the panel, the icon and Settings.
@MainActor @Observable
final class UpdateController: NSObject, SPUUpdaterDelegate {
    /// Published one by one and only on a change: the menu bar icon follows `showsBadge` alone and
    /// is not redrawn for every downloaded chunk.
    private(set) var state: UpdateState = .idle
    private(set) var showsBadge = false
    /// Sparkle can take a manual check: the updater runs and no other check is under way.
    private(set) var canCheckNow = false
    let currentVersion: String
    let currentBuild: String

    @ObservationIgnored private var model = UpdateModel()
    @ObservationIgnored private let feedOverride: String?
    @ObservationIgnored private let onWillRelaunch: @MainActor () -> Void
    @ObservationIgnored private var driver: PanelUserDriver!
    @ObservationIgnored private var updater: SPUUpdater!
    @ObservationIgnored private var canCheckObservation: NSKeyValueObservation?
    /// An offer withdrawn on expiry is checked again as soon as Sparkle closes its session.
    @ObservationIgnored private var recheckAfterCycle = false
    @ObservationIgnored private let logger = Logger(subsystem: "io.github.aesarva.Lidless", category: "updates")

    /// `feedOverride`: a feed instead of `SUFeedURL` (launch argument `-UpdateFeedURL`);
    /// `offerLifetime`: how long an offer stays up uninstalled (launch argument
    /// `-UpdateOfferLifetime <seconds>`, any build); `lidIsOpen`: whether installing (and so quitting) is safe
    /// now; `onWillRelaunch`: Sparkle is about to quit this copy for the new one.
    init(feedOverride: String?, offerLifetime: Duration = .seconds(24 * 60 * 60),
         onShowPanel: @escaping () -> Void, lidIsOpen: @escaping @MainActor () -> Bool,
         onWillRelaunch: @escaping @MainActor () -> Void) {
        self.feedOverride = feedOverride
        self.onWillRelaunch = onWillRelaunch
        currentVersion = Bundle.main.shortVersion
        currentBuild = Bundle.main.buildVersion
        super.init()
        driver = PanelUserDriver(offerLifetime: offerLifetime,
                                 lidIsOpen: lidIsOpen,
                                 onEvent: { [weak self] in self?.apply($0) },
                                 onShowPanel: onShowPanel,
                                 onOfferExpired: { [weak self] in self?.recheckAfterCycle = true })
        updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: self)
        // Sparkle changes canCheckForUpdates on the main thread only.
        canCheckObservation = updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            MainActor.assumeIsolated { self?.canCheckNow = updater.canCheckForUpdates }
        }
    }

    var automaticallyChecks: Bool {
        get {
            access(keyPath: \.automaticallyChecks)
            return updater.automaticallyChecksForUpdates
        }
        set {
            withMutation(keyPath: \.automaticallyChecks) { updater.automaticallyChecksForUpdates = newValue }
        }
    }

    func start() {
        let bundle = Bundle.main.bundleURL
        let readOnly = (try? bundle.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly ?? false
        guard UpdateLocation.canUpdate(bundlePath: bundle.path, volumeIsReadOnly: readOnly) else {
            apply(.locationUnsupported)
            return
        }
        do {
            try updater.start()
        } catch {
            let ns = error as NSError
            logger.error("Updater failed to start \(ns.domain, privacy: .public) \(ns.code): \(ns.localizedDescription, privacy: .public)")
            apply(Self.event(for: error, userInitiated: true))
        }
    }

    func install() {
        guard case .available = state else { return }
        driver.install()
    }

    /// A manual check; also "Retry" after an error.
    func checkNow() {
        guard canCheckNow else { return }
        updater.checkForUpdates()
    }

    /// Readings with the lid open: an install waiting for it goes ahead.
    func lidDidOpen() {
        driver.lidDidOpen()
    }

    // MARK: SPUUpdaterDelegate

    func feedURLString(for updater: SPUUpdater) -> String? {
        feedOverride
    }

    /// "What's new" opens the release page in the browser on a click; nothing is fetched for it.
    func updater(_ updater: SPUUpdater, shouldDownloadReleaseNotesForUpdate updateItem: SUAppcastItem) -> Bool {
        false
    }

    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        onWillRelaunch()
    }

    /// The end of any check. A background check without an update never calls the UI; this is the
    /// only place it is heard from.
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        // Sparkle has closed its session by now and lets a new one start.
        if recheckAfterCycle {
            recheckAfterCycle = false
            updater.checkForUpdatesInBackground()
            return
        }
        switch UpdateErrors.cycleOutcome(failed: error != nil, sparkleCode: Self.sparkleCode(of: error)) {
        case .succeeded:
            if updateCheck == .updatesInBackground { apply(.backgroundCheckSucceeded) }
        case .installCanceled:
            // The administrator password prompt was cancelled. Sparkle closed the session quietly:
            // offer the update again, or it would be gone until the next daily check. Right here,
            // as above: later, a check Sparkle schedules meanwhile could hold the session.
            updater.checkForUpdatesInBackground()
        case .failed:
            break
        }
    }

    static func event(for error: any Error, userInitiated: Bool) -> UpdateEvent {
        UpdateErrors.event(sparkleCode: sparkleCode(of: error), message: error.localizedDescription,
                           userInitiated: userInitiated)
    }

    private static func sparkleCode(of error: (any Error)?) -> Int? {
        guard let error = error as NSError?, error.domain == SUSparkleErrorDomain else { return nil }
        return error.code
    }

    private func apply(_ event: UpdateEvent) {
        model.apply(event)
        if model.state != state { state = model.state }
        if model.showsBadge != showsBadge { showsBadge = model.showsBadge }
    }
}
