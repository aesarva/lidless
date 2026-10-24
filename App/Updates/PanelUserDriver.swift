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
    /// Until it is answered, Sparkle checks for nothing else. After a day the offer is withdrawn
    /// and checked again, so a Lidless running for weeks does not offer 0.4.1 once 0.4.2 is out.
    private var offerExpiry: Task<Void, Never>?
    private let offerLifetime: Duration
    /// Quitting for the relaunch gives normal sleep back, so a closed lid holds the install.
    private let gate = InstallGate()
    /// A manual check: its result and errors are shown, a background check's are not.
    private var userInitiated = false
    private let logger = Logger(subsystem: "io.github.aesarva.Lidless", category: "updates")

    /// `offerLifetime`: how long an offer stays up uninstalled (a day; shorter only for debugging).
    init(offerLifetime: Duration, lidIsOpen: @escaping @MainActor () -> Bool,
         onEvent: @escaping (UpdateEvent) -> Void, onShowPanel: @escaping () -> Void,
         onOfferExpired: @escaping () -> Void) {
        self.offerLifetime = offerLifetime
        self.lidIsOpen = lidIsOpen
        self.onEvent = onEvent
        self.onShowPanel = onShowPanel
        self.onOfferExpired = onOfferExpired
    }

    func install() {
        reply(.install)
    }

    /// The lid is open: an install held for it goes ahead now. Plain readings change nothing.
    func lidDidOpen() {
        if gate.lidOpened() { onEvent(.installing) }
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
        offerExpiry?.cancel()
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
        onEvent(.found(version: appcastItem.displayVersionString,
                       notesURL: appcastItem.releaseNotesURL ?? appcastItem.infoURL))
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
        onEvent(.installing)
        // Closed (or in clamshell): the answer waits for `lidDidOpen()`.
        if !gate.ready(lidOpen: lidIsOpen(), reply: { reply(.install) }) {
            logger.info("Install waits for the lid to open")
            onEvent(.waitingForOpenLid)
        }
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
        gate.cancel()
        userInitiated = false
        onEvent(.dismissed)
    }
}
