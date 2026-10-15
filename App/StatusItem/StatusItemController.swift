import AppKit
import SwiftUI
import WakeUpCore

@MainActor
final class StatusItemController {
    private let controller: SessionController
    private let helper: HelperModel
    private let popover = NSPopover()
    private let item: NSStatusItem
    private var lastPresentation: StatusPresentation?
    private let openSettings: (SettingsTab) -> Void

    init(controller: SessionController, helper: HelperModel, openSettings: @escaping (SettingsTab) -> Void) {
        self.controller = controller
        self.helper = helper
        self.openSettings = openSettings
        let popover = self.popover
        let host = NSHostingController(
            rootView: PopoverView(controller: controller, helper: helper) { tab in
                popover.performClose(nil)
                openSettings(tab)
            }
        )
        host.sizingOptions = .preferredContentSize
        popover.behavior = .transient
        popover.contentViewController = host
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.target = self
            button.action = #selector(clicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        refresh()
    }

    func refresh() {
        let presentation = StatusPresentation.make(
            state: controller.state,
            attention: controller.attention,
            showTimerText: controller.settings.showTimerInMenuBar,
            now: Date()
        )
        guard presentation != lastPresentation, let button = item.button else { return }
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
            popover.performClose(nil)
            helper.refresh()
            item.menu = QuickMenu.build(
                controller: controller,
                helperInstalled: helper.status == .installed,
                onSettings: openSettings
            )
            item.button?.performClick(nil)
            item.menu = nil
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        guard let button = item.button else { return }
        controller.clearAttention()
        helper.refresh()
        refresh()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
    }
}
