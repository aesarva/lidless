import SwiftUI
import LidlessCore

/// One labelled switch row on the studio panel.
private struct SwitchRow: View {
    let title: String
    let detail: String
    var detailColor: Color = Studio.inkDim
    @Binding var isOn: Bool
    var enabled = true
    /// Red only while on air; off air an enabled setting is shown in studio ink.
    var onAir = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(Studio.ink)
                Text(detail).font(.system(size: 11)).foregroundStyle(detailColor)
                    // Fixed two-line slot: switching states never resizes the panel.
                    .lineLimit(2)
                    .frame(height: 28, alignment: .topLeading)
                    .help(detail)
            }
            Spacer(minLength: 8)
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(onAir ? Studio.onAir : Studio.inkDim)
                .controlSize(.small)
                .disabled(!enabled)
        }
        .padding(.vertical, 9)
        .accessibilityElement(children: .combine)
    }
}

struct DisplayRow: View {
    let controller: SessionController

    var body: some View {
        let on = controller.session?.keepDisplayOn ?? controller.settings.keepDisplayOn
        SwitchRow(
            title: String(localized: "Keep display on"),
            detail: on ? String(localized: "the screen stays lit") : String(localized: "the screen may sleep"),
            isOn: Binding(get: { on }, set: { controller.setKeepDisplayOn($0) }),
            onAir: controller.session != nil
        )
    }
}

struct LidRow: View {
    let controller: SessionController
    let helper: HelperModel
    @State private var installError: HelperError?

    private var suspended: SafetyReason? { controller.session?.lidModeSuspendedReason }

    /// What the switch shows: during a session, lid mode the session wants (on its way or
    /// waiting for the helper counts as on, the detail says why it is not held yet; a safety
    /// pause is off), the setting otherwise.
    private var isOn: Bool {
        controller.session != nil ? controller.lidModeWanted : controller.settings.lidModeEnabled
    }

    private var detail: (String, Color) {
        if let installError {
            return (String(localized: "helper error: \(installError.message)"), Studio.caution)
        }
        switch helper.status {
        case .notInstalled:
            return (String(localized: "needs a one-time approval in System Settings"), Studio.caution)
        case .needsApproval:
            return (String(localized: "allow Lidless in System Settings → Login Items"), Studio.caution)
        case .checking:
            return (String(localized: "checking…"), Studio.inkDim)
        case .unsigned:
            return (String(localized: "needs a signed build"), Studio.caution)
        case .error(let message):
            return (String(localized: "helper error: \(message)"), Studio.caution)
        case .installed:
            break
        }
        if controller.session?.lidModePending == true {
            return (String(localized: "turning on…"), Studio.inkDim)
        }
        if let reason = suspended {
            switch reason {
            case .thermal: return (String(localized: "paused: the Mac is hot"), Studio.caution)
            case .lidOnBatteryLimit: return (String(localized: "paused: battery time limit"), Studio.caution)
            case .helperUnavailable: return (String(localized: "paused: helper error"), Studio.caution)
            case .lowBattery: return (String(localized: "paused: low battery"), Studio.caution)
            }
        }
        if isOn, controller.session != nil {
            return (String(localized: "screen goes dark, the Mac keeps running"), Studio.inkDim)
        }
        if isOn {
            return (String(localized: "on air: screen goes dark, the Mac keeps running"), Studio.inkDim)
        }
        return (String(localized: "closing the lid puts the Mac to sleep"), Studio.inkDim)
    }

    var body: some View {
        SwitchRow(
            title: String(localized: "Closed-lid mode"),
            detail: detail.0,
            detailColor: detail.1,
            isOn: Binding(get: { isOn }, set: { _ in Task { await tap() } }),
            enabled: !helper.isWorking && helper.status != .unsigned,
            onAir: controller.session != nil
        )
        // An install error is about the status it happened in.
        .onChange(of: helper.status) { installError = nil }
    }

    private func tap() async {
        // Lid mode the session wants, held or waiting for the helper (approval, a check, an
        // install): the switch turns it off.
        if controller.session != nil, isOn {
            installError = nil
            controller.setLidMode(false)
            return
        }
        switch helper.status {
        case .unsigned:
            return
        case .needsApproval:
            helper.openSystemSettings()
        case .notInstalled:
            guard !helper.isWorking else { return }
            installError = nil
            if let error = await helper.install() {
                installError = error
                return
            }
            // Wanted now, applied once the user allows the helper (HelperModel.onBecameInstalled).
            controller.setLidMode(true)
        case .installed, .checking, .error:
            // Checking: wanted now, applied once the daemon has answered. A safety pause shows
            // off: the user's enable lifts it (unless the rule still holds).
            installError = nil
            controller.setLidMode(!isOn)
        }
    }
}
