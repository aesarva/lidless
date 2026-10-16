import SwiftUI
import LidlessCore

/// Remaining (or elapsed) time at headline scale and what it means underneath. The session
/// itself is switched by pressing the ON AIR sign above.
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
                        // Two lines always reserved: on/off/blocked captions never change the panel height.
                        .lineLimit(2)
                        .frame(height: 32, alignment: .topLeading)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func headline(now: Date) -> String {
        guard let s = controller.session else { return "—" } // off air: no timer to show
        if let end = s.endsAt { return StatusPresentation.formatRemaining(end.timeIntervalSince(now)) }
        return "∞" // indefinite: time on air already counts on the sign
    }

    private func caption(now: Date) -> String {
        guard let s = controller.session else {
            if case .lowBattery(let threshold)? = controller.startBlock {
                return String(localized: "Battery below \(threshold)% — connect power or change the limit")
            }
            return String(localized: "Press the sign to go on air")
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
