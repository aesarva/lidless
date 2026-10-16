import AppKit
import SwiftUI
import LidlessCore

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
            let host = NSHostingController(rootView: view)
            // The window follows each tab's natural height, so no tab is ever clipped.
            host.sizingOptions = [.preferredContentSize]
            let window = NSWindow(contentViewController: host)
            window.styleMask = [.titled, .closable]
            window.title = String(localized: "Lidless Settings")
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}
