import AppKit
import SwiftUI

/// Borderless panel that may become key: it is active from the first frame, so nothing
/// renders in the inactive (greyed) state, and it never activates the Dock-less app's windows.
private final class StudioPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// The studio panel shown under the status item, the way macOS shows its own menu-bar
/// panels: no arrow, solid ground, closes on Escape, on a click elsewhere or when it loses key.
@MainActor
final class PanelController {
    private let panel: StudioPanel
    private weak var anchor: NSStatusBarButton?
    private var clickMonitor: Any?
    private var keyMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    var onClose: (() -> Void)?

    var isShown: Bool { panel.isVisible }

    init<Content: View>(content: Content) {
        panel = StudioPanel(contentRect: NSRect(x: 0, y: 0, width: Studio.panelWidth, height: 400),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.transient, .ignoresCycle, .moveToActiveSpace, .fullScreenAuxiliary]
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.animationBehavior = .utilityWindow

        let host = NSHostingView(rootView: AnyView(
            content
                .clipShape(RoundedRectangle(cornerRadius: Studio.corner, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Studio.corner, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
                .fixedSize()
        ))
        host.sizingOptions = [.intrinsicContentSize]
        panel.contentView = host
        // Content height changes with state (a caption wraps, an install error appears):
        // keep the panel's top edge under the menu bar.
        NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: host, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.reposition() } }
        host.postsFrameChangedNotifications = true
    }

    func toggle(below button: NSStatusBarButton) {
        isShown ? close() : show(below: button)
    }

    func show(below button: NSStatusBarButton) {
        anchor = button
        panel.contentView?.layoutSubtreeIfNeeded()
        reposition()
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        // Activation of a menu-bar app is cooperative and may land a turn later; make sure
        // the panel ends up key so nothing renders in the inactive state.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isShown, !self.panel.isKeyWindow else { return }
                self.panel.makeKey()
            }
        }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53, let self, self.panel.isKeyWindow else { return event } // Escape
            MainActor.assumeIsolated { self.close() }
            return nil
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
        ) { [weak self] _ in
            // The new key window is known only after this notification: decide on the next turn.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.isShown, !self.panel.isKeyWindow else { return }
                    // A child popover (the "Until…" time picker) takes key; stay open for it.
                    if let key = NSApp.keyWindow, key.isDescendant(of: self.panel) { return }
                    self.close()
                }
            }
        }
    }

    #if DEBUG
    /// Writes the live panel (key window, real control states) to a PNG.
    func capture(to url: URL) {
        guard let view = panel.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        print("captured \(url.path) key=\(panel.isKeyWindow)")
    }
    #endif

    func close() {
        guard isShown else { return }
        panel.orderOut(nil)
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        clickMonitor = nil
        keyMonitor = nil
        resignObserver = nil
        onClose?()
    }

    private func reposition() {
        guard let button = anchor, let buttonWindow = button.window,
              let screen = buttonWindow.screen ?? NSScreen.main else { return }
        // Width is the panel's design width, never a transient fitting width mid-layout.
        let fitting = panel.contentView?.fittingSize ?? panel.frame.size
        let size = NSSize(width: Studio.panelWidth, height: fitting.height)
        let buttonFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let visible = screen.visibleFrame
        var x = buttonFrame.midX - size.width / 2
        x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
        let y = buttonFrame.minY - 6 - size.height
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
    }
}

private extension NSWindow {
    func isDescendant(of ancestor: NSWindow) -> Bool {
        var w = parent
        while let current = w {
            if current === ancestor { return true }
            w = current.parent
        }
        return false
    }
}
