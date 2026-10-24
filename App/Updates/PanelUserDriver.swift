import Foundation
import LidlessCore
import OSLog
import Sparkle

/// Sparkle without its windows: turns its calls into `UpdateEvent`s and leaves the showing to the
/// panel and the icon. The decisions Sparkle waits on are made here: install on the panel's
/// button, relaunch right away without a second click, but only with the lid open (spec §4).
@MainActor
final class PanelUserDriver: NSObject, SPUUserDriver {
    private let onEvent: (UpdateEvent) -> Void
    private let onShowPanel: () -> Void
    private let onOfferExpired: () -> Void
    private let lidIsOpen: @MainActor () -> Bool
    /// Sparkle's answer to a found update; called exactly once.
    private var pendingChoice: ((SPUUserUpdateChoice) -> Void)?
    /// How far the offered update already got. `.installing` (resumed after an earlier launch):
    /// "install" quits and relaunches at once, with no `showReady` in between.
    private var pendingStage: SPUUserUpdateStage = .notDownloaded
    /// Until it is answered, Sparkle checks for nothing else. After a day the offer is withdrawn
    /// and checked again, so a Lidless running for weeks does not offer 0.4.1 once 0.4.2 is out.
    private var offerExpiry: Task<Void, Never>?
    private let offerLifetime: Duration
    /// The user's "Check for updates automatically": only then does an offer expire (and get
    /// checked again).
    private let automaticChecks: @MainActor () -> Bool
    /// Quitting for the relaunch gives normal sleep back, so a closed lid holds the install.
    private let gate = InstallGate()
    /// A manual check: its result and errors are shown, a background check's are not.
    private var userInitiated = false
    private let logger = Logger(subsystem: "io.github.aesarva.Lidless", category: "updates")

    /// `offerLifetime`: how long an offer stays up uninstalled (a day; shorter only for debugging).
    init(offerLifetime: Duration, automaticChecks: @escaping @MainActor () -> Bool,
         lidIsOpen: @escaping @MainActor () -> Bool,
         onEvent: @escaping (UpdateEvent) -> Void, onShowPanel: @escaping () -> Void,
         onOfferExpired: @escaping () -> Void) {
        self.offerLifetime = offerLifetime
        self.automaticChecks = automaticChecks
        self.lidIsOpen = lidIsOpen
        self.onEvent = onEvent
        self.onShowPanel = onShowPanel
        self.onOfferExpired = onOfferExpired
    }

    func install() {
        guard pendingStage == .installing else {
            // Downloading and extracting come first; the relaunch waits at `showReady`.
            reply(.install)
            return
        }
        offerExpiry?.cancel()
        offerExpiry = nil
        guard let reply = pendingChoice else { return }
        pendingChoice = nil
        relaunchWhenLidOpen { reply(.install) }
    }

    /// The user turned automatic checks on or off: an offer on display expires (with the full
    /// lifetime from now) only while they are on.
    func automaticChecksChanged() {
        offerExpiry?.cancel()
        offerExpiry = nil
        if pendingChoice != nil { scheduleOfferExpiry() }
    }

    /// The lid is open: an install held for it goes ahead now. Plain readings change nothing.
    func lidDidOpen() {
        if gate.lidOpened() { onEvent(.installing) }
    }

    /// Every answer that quits for the relaunch goes through here: at once with the lid open,
    /// otherwise held until `lidDidOpen()`.
    private func relaunchWhenLidOpen(_ install: @escaping () -> Void) {
        if gate.ready(lidOpen: lidIsOpen(), reply: install) {
            onEvent(.installing)
        } else {
            logger.info("Install waits for the lid to open")
            onEvent(.waitingForOpenLid)
        }
    }

    private func reply(_ choice: SPUUserUpdateChoice) {
        offerExpiry?.cancel()
        offerExpiry = nil
        guard let reply = pendingChoice else { return }
        pendingChoice = nil
        reply(choice)
    }

    // MARK: Checking

    func show(_ request: SPUUpdatePermissionRequest,
              reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        userInitiated = true
        onEvent(.checkStarted(userInitiated: true))
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState,
                         reply: @escaping (SPUUserUpdateChoice) -> Void) {
        userInitiated = false
        pendingChoice = reply
        pendingStage = state.stage
        offerExpiry?.cancel()
        offerExpiry = nil
        scheduleOfferExpiry()
        onEvent(.found(version: appcastItem.displayVersionString,
                       notesURL: appcastItem.releaseNotesURL ?? appcastItem.infoURL))
    }

    /// Without automatic checks the offer stays up: nothing would find it again once withdrawn.
    private func scheduleOfferExpiry() {
        guard UpdateErrors.offerExpires(automaticChecks: automaticChecks()) else { return }
        offerExpiry = Task { [weak self] in
            guard let lifetime = self?.offerLifetime else { return }
            try? await Task.sleep(for: lifetime, clock: .continuous)
            guard !Task.isCancelled, let self, self.pendingChoice != nil else { return }
            // Sparkle handles the answer asynchronously and its session is still open: the
            // controller starts the new check once Sparkle reports the cycle's end.
            self.onEvent(.offerExpired)
            self.onOfferExpired()
            self.reply(.dismiss)
        }
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {}

    func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        logger.info("No update: \((error as NSError).code)")
        onEvent(.notFound(userInitiated: userInitiated))
        userInitiated = false
        acknowledgement()
    }

    func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        let ns = error as NSError
        logger.error("Updater error \(ns.domain, privacy: .public) \(ns.code): \(ns.localizedDescription, privacy: .public)")
        onEvent(UpdateController.event(for: error, userInitiated: userInitiated))
        userInitiated = false
        acknowledgement()
    }

    // MARK: Downloading and installing

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        onEvent(.downloadStarted)
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        onEvent(.expectedLength(expectedContentLength))
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        onEvent(.received(length))
    }

    func showDownloadDidStartExtractingUpdate() {
        onEvent(.installing)
    }

    func showExtractionReceivedProgress(_ progress: Double) {}

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        relaunchWhenLidOpen { reply(.install) }
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool,
                              retryTerminatingApplication: @escaping () -> Void) {
        onEvent(.installing)
        // Lidless never blocks quitting, but if something held it up, ask again rather than hang
        // on "Installing…".
        guard !applicationTerminated else { return }
        Task {
            try? await Task.sleep(for: .seconds(5))
            retryTerminatingApplication()
        }
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        acknowledgement()
    }

    func showUpdateInFocus() {
        onShowPanel()
    }

    func dismissUpdateInstallation() {
        offerExpiry?.cancel()
        offerExpiry = nil
        pendingChoice = nil
        pendingStage = .notDownloaded
        gate.cancel()
        userInitiated = false
        onEvent(.dismissed)
    }
}
