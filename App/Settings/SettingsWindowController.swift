import AppKit
import SwiftUI
import WakeUpCore

@MainActor
final class SettingsWindowController {
    private let controller: SessionController
    private let helper: HelperModel
    private let loginItem = LoginItem()
    private let navigation = SettingsNavigation()
    private var window: NSWindow?

    init(controller: SessionController, helper: HelperModel) {
        self.controller = controller
        self.helper = helper
    }

    func show(tab: SettingsTab) {
        navigation.tab = tab
        helper.refresh()
        loginItem.refresh()
        if window == nil {
            let view = SettingsView(controller: controller, helper: helper, loginItem: loginItem, navigation: navigation)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 480, height: 400),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = String(localized: "WakeUp Settings")
            window.contentView = NSHostingView(rootView: view)
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}
