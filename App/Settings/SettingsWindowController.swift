import AppKit
import SwiftUI
import LidlessCore

@MainActor
final class SettingsWindowController {
    private let controller: SessionController
    private let helper: HelperModel
    private let updates: any UpdateSource
    private let loginItem = LoginItem()
    private var window: NSWindow?

    init(controller: SessionController, helper: HelperModel, updates: any UpdateSource) {
        self.controller = controller
        self.helper = helper
        self.updates = updates
    }

    func show(tab: SettingsTab) {
        helper.refresh()
        loginItem.refresh()
        if window == nil {
            // A standard preferences window: tabs with icons in the toolbar, and the window takes
            // each tab's height. Its title is the selected tab's name.
            let tabs = NSTabViewController()
            tabs.tabStyle = .toolbar
            for tab in SettingsTab.allCases {
                let host = NSHostingController(rootView: tab
                    .content(controller: controller, helper: helper, loginItem: loginItem, updates: updates)
                    .fittedForm()
                    .frame(width: 420))
                host.sizingOptions = [.preferredContentSize]
                host.title = tab.title
                let item = NSTabViewItem(viewController: host)
                item.label = tab.title
                item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.title)
                tabs.addTabViewItem(item)
            }
            let window = NSWindow(contentViewController: tabs)
            window.styleMask = [.titled, .closable]
            window.toolbarStyle = .preference
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        if let tabs = window?.contentViewController as? NSTabViewController,
           let index = SettingsTab.allCases.firstIndex(of: tab) {
            tabs.selectedTabViewItemIndex = index
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    #if DEBUG
    /// Debug aid for `-SnapshotDir`: the whole window, toolbar included, for every tab.
    func exportSnapshots(to dir: URL, appearance: NSAppearance.Name, suffix: String) async {
        show(tab: .general)
        guard let window else { return }
        window.appearance = NSAppearance(named: appearance)
        for tab in SettingsTab.allCases {
            show(tab: tab)
            try? await Task.sleep(for: .milliseconds(700)) // the window animates its height per tab
            guard let frame = window.contentView?.superview,
                  let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { continue }
            frame.cacheDisplay(in: frame.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?
                .write(to: dir.appendingPathComponent("window-settings-\(tab.symbol)-\(suffix).png"))
        }
        window.close()
        window.appearance = nil
    }
    #endif
}
