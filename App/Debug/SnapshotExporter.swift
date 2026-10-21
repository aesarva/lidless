#if DEBUG
import AppKit
import LidlessCore
import SwiftUI

/// Debug aid: `-SnapshotDir <path>` renders every popover state, each settings tab and the
/// menu-bar glyphs to PNGs in light and dark, without Screen Recording access, then quits.
@MainActor
enum SnapshotExporter {
    static func export(to directory: String) {
        let dir = URL(fileURLWithPath: directory, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let suffix = appearance == .aqua ? "light" : "dark"
            NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
                for (name, view) in popoverStates() {
                    snapshot(popoverStage(view), appearance: appearance,
                             to: dir.appendingPathComponent("popover-\(name)-\(suffix).png"))
                }
                let migrated = HelperModel(backend: PreviewBackend(.installed))
                migrated.markLegacyRemovedForPreview()
                for (name, tab, helper) in [
                    ("general", SettingsTab.general, HelperModel(backend: PreviewBackend(.installed))),
                    ("safety", .safety, HelperModel(backend: PreviewBackend(.installed))),
                    ("helper", .helper, migrated),
                    ("helper-needs-approval", .helper, HelperModel(backend: PreviewBackend(.needsApproval))),
                    ("helper-unsigned", .helper, HelperModel(backend: PreviewBackend(.unsigned))),
                    ("about", .about, HelperModel(backend: PreviewBackend(.installed))),
                ] {
                    let nav = SettingsNavigation()
                    nav.tab = tab
                    let view = SettingsView(controller: previewController(readings: previewReadings()),
                                            helper: helper, loginItem: LoginItem(), navigation: nav)
                        .background(Color(nsColor: .windowBackgroundColor))
                    snapshot(view, appearance: appearance,
                             to: dir.appendingPathComponent("settings-\(name)-\(suffix).png"))
                }
                snapshot(menuBarStrip(), appearance: appearance,
                         to: dir.appendingPathComponent("menubar-\(suffix).png"))
            }
        }
    }

    private static func popoverStates() -> [(String, AnyView)] {
        func view(_ c: SessionController, helper: HelperStatus = .installed) -> AnyView {
            AnyView(PopoverView(controller: c, helper: HelperModel(backend: PreviewBackend(helper)),
                                openSettings: { _ in }))
        }
        let off = previewController(readings: previewReadings())
        let indefinite = previewController(readings: previewReadings())
        indefinite.start(.indefinite)
        let timerLid = previewController(lid: true, readings: previewReadings())
        timerLid.start(.minutes(60))
        let blocked = previewController(readings: previewReadings(battery: 12, onBattery: true))
        blocked.start(.indefinite)
        let paused = previewController(lid: true)
        paused.start(.minutes(180))
        paused.update(readings: previewReadings(thermal: .serious))
        return [
            ("off", view(off)),
            ("indefinite", view(indefinite)),
            ("timer-lid", view(timerLid)),
            ("blocked", view(blocked)),
            ("lid-paused", view(paused)),
            ("not-set-up", view(previewController(readings: previewReadings()), helper: .notInstalled)),
            ("needs-approval", view(previewController(lid: true, readings: previewReadings()), helper: .needsApproval)),
            ("unsigned", view(previewController(readings: previewReadings()), helper: .unsigned)),
        ]
    }

    /// The panel as PanelController frames it, over a wallpaper-like ground.
    private static func popoverStage(_ content: AnyView) -> some View {
        content
            .clipShape(RoundedRectangle(cornerRadius: Studio.corner, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Studio.corner, style: .continuous)
                .strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 18, y: 10)
            .padding(28)
            .background(LinearGradient(colors: [Color(red: 0.17, green: 0.23, blue: 0.40),
                                                Color(red: 0.42, green: 0.24, blue: 0.42),
                                                Color(red: 0.77, green: 0.42, blue: 0.29)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing))
    }

    private static func menuBarStrip() -> some View {
        let now = Date()
        let states: [StatusPresentation] = {
            let off = previewController(readings: previewReadings())
            let on = previewController(readings: previewReadings()); on.start(.indefinite)
            let timer = previewController(readings: previewReadings()); timer.start(.minutes(60))
            let lid = previewController(lid: true, readings: previewReadings()); lid.start(.minutes(60))
            return [off, on, timer, lid].map {
                StatusPresentation.make(state: $0.state, attention: nil, showTimerText: true, now: now)
            } + [StatusPresentation.make(state: .off, attention: .lowBattery, showTimerText: false, now: now)]
        }()
        return HStack(spacing: 18) {
            ForEach(Array(states.enumerated()), id: \.offset) { _, p in
                HStack(spacing: 3) {
                    Image(nsImage: IconRenderer.image(for: p)).renderingMode(p.glyph == .off ? .template : .original)
                    if let t = p.timerText { Text(t).font(.system(size: 13).monospacedDigit()) }
                }
            }
        }
        .padding(.horizontal, 12).frame(height: 28)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private static func snapshot<V: View>(_ view: V, appearance: NSAppearance.Name, to url: URL) {
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: appearance)
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
#endif
