import SwiftUI
import LidlessCore

/// One caption under the sign: what the session means right now. The time itself lives on
/// the sign (a countdown for a timed session, time on air for an indefinite one).
struct SessionHeader: View {
    let controller: SessionController

    var body: some View {
        Text(caption)
            .font(.system(size: 12))
            .monospacedDigit()
            .foregroundStyle(controller.startBlock != nil && controller.session == nil
                             ? Studio.caution : Studio.inkDim)
            // Two lines always reserved: on/off/blocked captions never change the panel height.
            .lineLimit(2)
            .frame(maxWidth: .infinity, minHeight: 32, maxHeight: 32, alignment: .topLeading)
    }

    private var caption: String {
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
        return String(localized: "until \(until)") + lid
    }
}
