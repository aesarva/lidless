import SwiftUI
import LidlessCore

enum SettingsTab { case general, safety, helper, about }

/// The studio panel under the menu-bar icon.
struct PopoverView: View {
    let controller: SessionController
    let helper: HelperModel
    let openSettings: (SettingsTab) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            OnAirSign(lit: controller.session != nil, since: controller.session?.startedAt,
                      until: controller.session?.endsAt) {
                withAnimation(.easeInOut(duration: 0.2)) { controller.toggle() }
            }
            SessionHeader(controller: controller)
            DurationPicker(controller: controller)
            MeterPlate(controller: controller) { openSettings(.safety) }
            VStack(spacing: 0) {
                DisplayRow(controller: controller)
                Rectangle().fill(Studio.hairline).frame(height: 1)
                LidRow(controller: controller, helper: helper)
            }
            footer
        }
        .padding(16)
        .frame(width: Studio.panelWidth)
        .background(Studio.panel)
        .environment(\.colorScheme, .dark)
        // The panel is the user's focus while open; controls never take the dimmed inactive look.
        .environment(\.controlActiveState, .key)
    }

    private var footer: some View {
        HStack {
            footerButton("gearshape", label: String(localized: "Settings")) { openSettings(.general) }
            Spacer()
            footerButton("power", label: String(localized: "Quit Lidless")) { NSApp.terminate(nil) }
        }
        .padding(.top, -4)
    }

    private func footerButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Studio.inkDim)
                .frame(width: 28, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}
