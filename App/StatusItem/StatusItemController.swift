import AppKit
import SwiftUI
import LidlessCore

@MainActor
final class StatusItemController {
    private let controller: SessionController
    private let helper: HelperModel
    private let updates: any UpdateSource
    private let panel: PanelController
    private let item: NSStatusItem
    private var lastPresentation: StatusPresentation?
    private var lastSpokenLabel: String?
    private let openSettings: (SettingsTab) -> Void

    init(controller: SessionController, helper: HelperModel, updates: any UpdateSource,
         openSettings: @escaping (SettingsTab) -> Void) {
        self.controller = controller
        self.helper = helper
        self.updates = updates
        self.openSettings = openSettings
        var closePanel: () -> Void = {}
        panel = PanelController(content: PopoverView(controller: controller, helper: helper, updates: updates) { tab in
            closePanel()
            openSettings(tab)
        })
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.target = self
            button.action = #selector(clicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        // Weak: the panel's own SwiftUI content holds this closure.
        closePanel = { [weak panel] in panel?.close() }
        refresh()
    }

    func refresh() {
        let presentation = StatusPresentation.make(
            state: controller.state,
            attention: controller.attention,
            updateAvailable: updates.showsBadge,
            showTimerText: controller.settings.showTimerInMenuBar,
            now: Date()
        )
        guard let button = item.button else { return }
        // Said even when the orange dot is the one drawn: the update is there all the same.
        let spoken = updates.showsBadge ? "Lidless, " + String(localized: "update available") : nil
        if spoken != lastSpokenLabel {
            lastSpokenLabel = spoken
            button.setAccessibilityLabel(spoken)
        }
        guard presentation != lastPresentation else { return }
        lastPresentation = presentation
        button.image = IconRenderer.image(for: presentation)
        if let text = presentation.timerText {
            button.attributedTitle = NSAttributedString(
                string: " " + text,
                attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 0, weight: .regular)]
            )
            button.imagePosition = .imageLeading
        } else {
            button.title = ""
            button.imagePosition = .imageOnly
        }
    }

    @objc private func clicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            panel.close()
            helper.refresh()
            item.menu = QuickMenu.build(
                controller: controller,
                helperStatus: helper.status,
                updates: updates,
                helperBusy: helper.isWorking,
                onSettings: openSettings
            )
            item.button?.performClick(nil)
            item.menu = nil
        } else {
            togglePopover()
        }
    }

    func openPanel() {
        if !panel.isShown { togglePopover() }
    }

    #if DEBUG
    func capturePanel(to url: URL) { panel.capture(to: url) }
    #endif

    private func togglePopover() {
        if panel.isShown {
            panel.close()
            return
        }
        // The same click already closed the panel by taking key from it: leave it closed.
        guard !panel.closedJustNow, let button = item.button else { return }
        controller.clearAttention()
        helper.refresh()
        refresh()
        panel.show(below: button)
    }
}
