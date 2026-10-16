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
                    .fixedSize(horizontal: false, vertical: true)
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

    /// What the switch shows: the live state during a session, the setting otherwise.
    private var isOn: Bool {
        if let s = controller.session { return s.lidModeActive }
        return controller.settings.lidModeEnabled
    }

    private var detail: (String, Color) {
        if helper.isWorking { return (String(localized: "installing the helper…"), Studio.inkDim) }
        if let installError {
            return (String(localized: "helper install failed: \(Self.describe(installError))"), Studio.caution)
        }
        if helper.status != .installed {
            return (String(localized: "needs a one-time helper install"), Studio.caution)
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
            return (String(localized: "on air the lid can close: screen goes dark, the Mac keeps running"), Studio.inkDim)
        }
        return (String(localized: "closing the lid puts the Mac to sleep"), Studio.inkDim)
    }

    var body: some View {
        SwitchRow(
            title: String(localized: "Closed-lid mode"),
            detail: detail.0,
            detailColor: detail.1,
            isOn: Binding(get: { isOn && suspended == nil }, set: { _ in Task { await tap() } }),
            enabled: !helper.isWorking,
            onAir: controller.session != nil
        )
    }

    private func tap() async {
        if helper.status != .installed {
            guard !helper.isWorking else { return }
            installError = nil
            let error = await helper.install()
            if let error {
                if error != .cancelled { installError = error }
                return
            }
            controller.helperDidChange()
            controller.setLidMode(true)
        } else if suspended != nil {
            controller.setLidMode(true)
        } else {
            // Decide on what the switch shows: after a failed disable the setting is off
            // but lid mode is still active, and a tap must retry the disable.
            controller.setLidMode(!isOn)
        }
    }

    private static func describe(_ e: HelperError) -> String {
        switch e {
        case .cancelled: return ""
        case .invalidUserName(let m), .commandFailed(let m), .installFailed(let m): return m
        }
    }
}
