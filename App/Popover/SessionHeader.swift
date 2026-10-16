import SwiftUI
import LidlessCore

/// Remaining (or elapsed) time at headline scale, what it means underneath, and the session switch.
struct SessionHeader: View {
    let controller: SessionController

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                VStack(alignment: .leading, spacing: 3) {
                    Text(headline(now: context.date))
                        .font(.system(size: 46, weight: .semibold, design: .default))
                        .monospacedDigit()
                        .tracking(-0.8)
                        .foregroundStyle(controller.session == nil ? Studio.inkFaint : Studio.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .contentTransition(.numericText())
                    Text(caption(now: context.date))
                        .font(.system(size: 12))
                        .monospacedDigit()
                        .foregroundStyle(controller.startBlock != nil && controller.session == nil
                                         ? Studio.caution : Studio.inkDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            Toggle(isOn: Binding(get: { controller.session != nil }, set: { _ in controller.toggle() })) {
                Text("Keep awake")
            }
            .labelsHidden()
            .toggleStyle(.switch)
            .tint(Studio.onAir)
            .controlSize(.large)
            .help(controller.session == nil ? String(localized: "Go on air") : String(localized: "Go off air"))
        }
    }

    private func headline(now: Date) -> String {
        guard let s = controller.session else { return "0:00" }
        if let end = s.endsAt { return StatusPresentation.formatRemaining(end.timeIntervalSince(now)) }
        return StatusPresentation.formatRemaining(now.timeIntervalSince(s.startedAt))
    }

    private func caption(now: Date) -> String {
        guard let s = controller.session else {
            if case .lowBattery(let threshold)? = controller.startBlock {
                return String(localized: "Battery below \(threshold)% — connect power or change the limit")
            }
            return String(localized: "Off air · the Mac sleeps as usual")
        }
        let lid = s.lidModeActive ? String(localized: " · lid can close") : ""
        guard let end = s.endsAt else {
            let since = s.startedAt.formatted(date: .omitted, time: .shortened)
            return String(localized: "on air since \(since)") + lid
        }
        let until = end.formatted(date: .omitted, time: .shortened)
        return String(localized: "left · until \(until)") + lid
    }
}
