import AppKit
import Observation
import ServiceManagement
import os

/// Launch-at-login backed by `SMAppService.mainApp`; the system status is the source of truth.
@MainActor @Observable final class LoginItem {
    @ObservationIgnored private let log = Logger(subsystem: "io.github.alexsarva.Lidless", category: "ui")
    private var current = SMAppService.mainApp.status == .enabled

    var isEnabled: Bool {
        get { current }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                log.error("Launch at login change failed: \(error.localizedDescription, privacy: .public)")
                present(error)
            }
            refresh()
        }
    }

    func refresh() {
        current = SMAppService.mainApp.status == .enabled
    }

    private func present(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Could not change the launch-at-login setting")
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }
}
