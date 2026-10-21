import AppKit
import LidlessCore

@MainActor
enum QuickMenu {
    static func build(
        controller: SessionController,
        helperInstalled: Bool,
        helperBusy: Bool = false,
        onSettings: @escaping (SettingsTab) -> Void = { _ in }
    ) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let isActive = controller.session != nil

        menu.addItem(ActionItem(isActive ? String(localized: "Turn Off") : String(localized: "Turn On")) {
            controller.toggle()
        })
        for minutes in controller.settings.presetMinutes {
            menu.addItem(ActionItem(presetTitle(minutes)) { presetAction(controller, .minutes(minutes)) })
        }
        menu.addItem(ActionItem(String(localized: "Indefinitely")) { presetAction(controller, .indefinite) })
        menu.addItem(.separator())

        let display = ActionItem(String(localized: "Keep Display On")) {
            controller.setKeepDisplayOn(!controller.settings.keepDisplayOn)
        }
        display.state = controller.settings.keepDisplayOn ? .on : .off
        menu.addItem(display)

        let lid = ActionItem(String(localized: "Closed-Lid Mode")) {
            let enabled = controller.settings.lidModeEnabled
            // Without the helper, turning lid mode on would only fail: send the user to install it.
            if !enabled && !helperInstalled {
                onSettings(.helper)
            } else {
                controller.setLidMode(!enabled)
            }
        }
        lid.state = controller.settings.lidModeEnabled ? .on : .off
        // No lid-mode changes while the helper is being installed or removed.
        lid.isEnabled = !helperBusy
        menu.addItem(lid)
        menu.addItem(.separator())

        menu.addItem(ActionItem(String(localized: "Settings…")) { onSettings(.general) })
        let quit = ActionItem(String(localized: "Quit Lidless")) { NSApp.terminate(nil) }
        quit.keyEquivalent = "q"
        quit.keyEquivalentModifierMask = .command
        menu.addItem(quit)
        return menu
    }

    private static func presetAction(_ controller: SessionController, _ duration: SessionDuration) {
        if controller.session != nil { controller.restart(duration) } else { controller.start(duration) }
    }

    private static func presetTitle(_ minutes: Int) -> String {
        if minutes % 60 == 0 { return String(localized: "\(minutes / 60) h") }
        return String(localized: "\(minutes) min")
    }
}

@MainActor
private final class ActionItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, action handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func fire() { handler() }
}
