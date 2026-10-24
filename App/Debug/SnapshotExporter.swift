#if DEBUG
import AppKit
import LidlessCore
import SwiftUI

/// Debug aid: `-SnapshotDir <path>` renders every popover state (each update row among them),
/// each settings tab (and the real window per tab) and the menu-bar glyphs to PNGs in light and dark, without Screen Recording
/// access, then quits. The language is the launch's own (`-AppleLanguages "(ru)"`).
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
                migrated.previewLegacy(removed: true)
                let legacyFailed = HelperModel(backend: PreviewBackend(.installed))
                legacyFailed.previewLegacy(removed: false, error: "cannot unlink /etc/sudoers.d/lidless: Operation not permitted")
                let installed = { HelperModel(backend: PreviewBackend(.installed)) }
                for (name, tab, helper, updates) in [
                    ("general", SettingsTab.general, installed(), UpdateState.upToDate),
                    ("general-update-failed", .general, installed(), .failed(message: sampleUpdateError)),
                    ("safety", .safety, installed(), .idle),
                    ("helper", .helper, migrated, .idle),
                    ("helper-needs-approval", .helper, HelperModel(backend: PreviewBackend(.needsApproval)), .idle),
                    ("helper-unsigned", .helper, HelperModel(backend: PreviewBackend(.unsigned)), .idle),
                    ("helper-legacy-error", .helper, legacyFailed, .idle),
                    ("about", .about, installed(), .idle),
                ] {
                    let view = tab
                        .content(controller: previewController(readings: previewReadings()), helper: helper,
                                 loginItem: LoginItem(), updates: PreviewUpdates(updates))
                        .fittedForm()
                        .frame(width: 420)
                        .background(Color(nsColor: .windowBackgroundColor))
                    snapshot(view, appearance: appearance,
                             to: dir.appendingPathComponent("settings-\(name)-\(suffix).png"))
                }
                snapshot(menuBarStrip(updateAvailable: false), appearance: appearance,
                         to: dir.appendingPathComponent("menubar-\(suffix).png"))
                snapshot(menuBarStrip(updateAvailable: true), appearance: appearance,
                         to: dir.appendingPathComponent("menubar-update-\(suffix).png"))
            }
        }
    }

    /// The real settings window per tab, toolbar included, in light and dark. Windows need the run
    /// loop to lay out, so this is async and runs after `export`.
    static func exportWindows(to directory: String) async {
        let dir = URL(fileURLWithPath: directory, isDirectory: true)
        let controller = SettingsWindowController(
            controller: previewController(readings: previewReadings()),
            helper: HelperModel(backend: PreviewBackend(.installed)), updates: PreviewUpdates(.upToDate))
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            await controller.exportSnapshots(to: dir, appearance: appearance,
                                             suffix: appearance == .aqua ? "light" : "dark")
        }
    }

    /// Long enough to wrap: Sparkle's messages are whole sentences.
    private static let sampleUpdateError = "The update is improperly signed and could not be validated. Please try again later or contact the app developer."

    private static func popoverStates() -> [(String, AnyView)] {
        func view(_ c: SessionController, helper: HelperStatus = .installed, updates: UpdateState = .idle) -> AnyView {
            AnyView(PopoverView(controller: c, helper: HelperModel(backend: PreviewBackend(helper)),
                                updates: PreviewUpdates(updates), openSettings: { _ in }))
        }
        let notes = URL(string: "https://github.com/aesarva/lidless/releases/tag/v0.4.1")
        let updateStates: [(String, UpdateState)] = [
            ("available", .available(version: "0.4.1", notesURL: notes)),
            ("available-no-notes", .available(version: "0.4.1", notesURL: nil)),
            ("downloading", .downloading(version: "0.4.1", progress: 0.42)),
            ("downloading-unknown", .downloading(version: "0.4.1", progress: nil)),
            ("installing", .installing(version: "0.4.1")),
            ("waiting-for-lid", .waitingForLid(version: "0.4.1")),
            ("failed", .failed(message: sampleUpdateError)),
            ("checking", .checking),
            ("needs-move", .needsMove),
            ("up-to-date", .upToDate),
        ]
        let onAir = previewController(lid: true, readings: previewReadings())
        onAir.start(.minutes(60))
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
            ("helper-error", view(previewController(lid: true, readings: previewReadings()),
                                  helper: .error("helper version 0.2.9 does not match Lidless 0.3.0"))),
            ("update-available-on-air", view(onAir, updates: .available(version: "0.4.1", notesURL: notes))),
        ] + updateStates.map { name, state in
            ("update-\(name)", view(previewController(readings: previewReadings()), updates: state))
        }
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

    /// Off, on air, timer, lid, then attention. With `updateAvailable` each wants the update dot
    /// too; the attention glyph, wanting both dots, draws only the orange one.
    private static func menuBarStrip(updateAvailable: Bool) -> some View {
        let now = Date()
        let states: [StatusPresentation] = {
            let off = previewController(readings: previewReadings())
            let on = previewController(readings: previewReadings()); on.start(.indefinite)
            let timer = previewController(readings: previewReadings()); timer.start(.minutes(60))
            let lid = previewController(lid: true, readings: previewReadings()); lid.start(.minutes(60))
            return [off, on, timer, lid].map {
                StatusPresentation.make(state: $0.state, attention: nil, updateAvailable: updateAvailable,
                                        showTimerText: true, now: now)
            } + [StatusPresentation.make(state: .off, attention: .lowBattery, updateAvailable: updateAvailable,
                                         showTimerText: false, now: now)]
        }()
        return HStack(spacing: 18) {
            ForEach(Array(states.enumerated()), id: \.offset) { _, p in
                HStack(spacing: 3) {
                    Image(nsImage: IconRenderer.image(for: p))
                        .renderingMode(p.glyph == .off && !p.updateDot ? .template : .original)
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
