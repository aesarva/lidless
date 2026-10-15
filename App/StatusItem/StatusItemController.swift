import AppKit
import WakeUpCore

@MainActor
final class StatusItemController {
    private let controller: SessionController
    private let onOpenPopover: () -> Void
    private let item: NSStatusItem
    private var lastPresentation: StatusPresentation?

    init(controller: SessionController, onOpenPopover: @escaping () -> Void) {
        self.controller = controller
        self.onOpenPopover = onOpenPopover
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
            item.menu = QuickMenu.build(controller: controller)
            item.button?.performClick(nil)
            item.menu = nil
        } else {
            onOpenPopover()
        }
    }
}
