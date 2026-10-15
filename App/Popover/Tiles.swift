import SwiftUI
import WakeUpCore

enum Tile {
    static let accent = Color(red: 1.0, green: 0.702, blue: 0.251) // #FFB340
    static let onAccent = Color(red: 0.114, green: 0.114, blue: 0.122)
}

private struct IconCircle: View {
    let symbol: String
    let active: Bool
    var size: CGFloat = 28

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(active ? Tile.onAccent : Color.primary)
            .frame(width: size, height: size)
            .background(Circle().fill(active ? Tile.accent : Color.primary.opacity(0.14)))
    }
}

/// Small clickable tile: icon circle + title + subtitle.
struct StatusTile: View {
    let symbol: String
    let title: String
    let subtitle: String
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                IconCircle(symbol: symbol, active: active)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.07)))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }
}

struct MainTile: View {
    let controller: SessionController

    var body: some View {
        HStack(spacing: 8) {
            IconCircle(symbol: "waveform.path.ecg", active: controller.session != nil, size: 36)
            VStack(alignment: .leading, spacing: 1) {
                Text(controller.session != nil ? "Awake" : "Off")
                    .font(.system(size: 14, weight: .semibold))
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(subtitle(now: context.date))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            Toggle("", isOn: Binding(get: { controller.session != nil }, set: { _ in controller.toggle() }))
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(.green)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.07)))
    }

    private func subtitle(now: Date) -> String {
        if case .lowBattery(let threshold)? = controller.startBlock, controller.session == nil {
            return String(localized: "Battery below \(threshold)% — connect power or change the limit")
        }
        guard let s = controller.session else { return String(localized: "Off") }
        guard let end = s.endsAt else { return String(localized: "Indefinitely") }
        let left = StatusPresentation.formatRemaining(end.timeIntervalSince(now))
        let until = end.formatted(date: .omitted, time: .shortened)
        return String(localized: "\(left) left · until \(until)")
    }
}

struct DisplayTile: View {
    let controller: SessionController

    var body: some View {
        let on = controller.session?.keepDisplayOn ?? controller.settings.keepDisplayOn
        StatusTile(
            symbol: "display", title: String(localized: "Display"),
            subtitle: on ? String(localized: "stays on") : String(localized: "may sleep"),
            active: on
        ) { controller.setKeepDisplayOn(!on) }
    }
}

struct LidTile: View {
    let controller: SessionController
    let helper: HelperModel
    @State private var installError: HelperError?

    private var suspended: SafetyReason? { controller.session?.lidModeSuspendedReason }

    private var isOn: Bool {
        if let s = controller.session { return s.lidModeActive }
        return controller.settings.lidModeEnabled
    }

    private var subtitle: String {
        if helper.status != .installed { return String(localized: "needs helper") }
        if let reason = suspended {
            switch reason {
            case .thermal: return String(localized: "paused: overheating")
            case .lidOnBatteryLimit: return String(localized: "paused: battery time limit")
            case .helperUnavailable, .lowBattery: return String(localized: "paused: helper error")
            }
        }
        return isOn ? String(localized: "keeps awake") : String(localized: "off")
    }

    var body: some View {
        StatusTile(
            symbol: "laptopcomputer", title: String(localized: "Lid"),
            subtitle: subtitle, active: isOn && suspended == nil && helper.status == .installed
        ) { Task { await tap() } }
        .alert(
            "Could not install the helper",
            isPresented: Binding(get: { installError != nil }, set: { if !$0 { installError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(verbatim: installError.map(Self.describe) ?? "")
        }
    }

    private func tap() async {
        if helper.status != .installed {
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
            // Decide on what the tile shows: after a failed disable the setting is off
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

struct BatteryTile: View {
    let controller: SessionController
    let openSettings: (SettingsTab) -> Void

    var body: some View {
        let level = controller.readings?.batteryLevel
        let safety = controller.settings.safety
        StatusTile(
            symbol: "battery.75percent",
            title: level.map { "\($0)%" } ?? "—",
            subtitle: safety.batteryRuleEnabled
                ? String(localized: "stop at \(safety.batteryThreshold)%") : String(localized: "rule off"),
            active: false
        ) { openSettings(.safety) }
    }
}

struct ThermalTile: View {
    let controller: SessionController
    let openSettings: (SettingsTab) -> Void

    var body: some View {
        let level = controller.readings?.thermal
        let text: String = switch level {
        case nil: "—"
        case .nominal?, .fair?: String(localized: "normal")
        case .serious?: String(localized: "elevated")
        case .critical?: String(localized: "high")
        }
        StatusTile(
            symbol: "thermometer.medium", title: String(localized: "Thermal"), subtitle: text, active: false
        ) { openSettings(.safety) }
    }
}
