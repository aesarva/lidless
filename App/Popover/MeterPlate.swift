import SwiftUI
import LidlessCore

/// Cream meter plate: battery and heat as 20-segment studio meters with their stop lines.
/// Clicking the plate opens the Safety settings.
struct MeterPlate: View {
    let controller: SessionController
    let openSafety: () -> Void

    var body: some View {
        Button(action: openSafety) {
            VStack(spacing: 9) {
                batteryRow
                thermalRow
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Studio.plate))
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(String(localized: "Safety settings"))
    }

    private var batteryRow: some View {
        let level = controller.readings?.batteryLevel
        let safety = controller.settings.safety
        let value: String = level.map { "\($0)%" } ?? "—"
        let note: String = {
            guard level != nil else { return String(localized: "no battery") }
            if controller.readings?.onBattery == false { return String(localized: "on power") }
            return safety.batteryRuleEnabled
                ? String(localized: "stop at \(safety.batteryThreshold)%") : String(localized: "rule off")
        }()
        return MeterRow(
            title: String(localized: "Battery"),
            value: value,
            note: note,
            lit: level.map { Int((Double($0) / 5).rounded(.up)) } ?? 0,
            liveFrom: nil,
            mark: (level != nil && safety.batteryRuleEnabled) ? safety.batteryThreshold / 5 : nil
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Battery \(value), \(note)"))
    }

    private var thermalRow: some View {
        let level = controller.readings?.thermal
        let (lit, value): (Int, String) = switch level {
        case nil: (0, "—")
        case .nominal?: (4, String(localized: "normal"))
        case .fair?: (8, String(localized: "normal"))
        case .serious?: (15, String(localized: "elevated"))
        case .critical?: (20, String(localized: "high"))
        }
        let note = controller.settings.safety.thermalRuleEnabled
            ? String(localized: "pauses when hot") : String(localized: "rule off")
        return MeterRow(title: String(localized: "Heat"), value: value, note: note,
                        lit: lit, liveFrom: 14, mark: nil)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Heat \(value), \(note)"))
    }
}

private struct MeterRow: View {
    let title: String
    let value: String
    let note: String
    /// Segments lit, 0...20.
    let lit: Int
    /// Segments from this index on are the red zone.
    let liveFrom: Int?
    /// Segment boundary drawn as the stop line (threshold / 5).
    let mark: Int?

    private static let count = 20

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(note).font(.system(size: 11)).foregroundStyle(Studio.plateInkDim)
                Text(value)
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
                    .frame(minWidth: 52, alignment: .trailing)
            }
            .foregroundStyle(Studio.plateInk)
            HStack(spacing: 2) {
                ForEach(0..<Self.count, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(color(at: i))
                        .frame(height: 7)
                        .overlay(alignment: .leading) {
                            if mark == i {
                                Rectangle().fill(Studio.onAir).frame(width: 1.5).offset(x: -1.75).padding(.vertical, -3)
                            }
                        }
                }
            }
            .animation(.easeOut(duration: 0.25), value: lit)
        }
    }

    private func color(at i: Int) -> Color {
        let live = liveFrom.map { i >= $0 } ?? false
        if i < lit { return live ? Studio.onAir : Studio.plateInk }
        return live ? Studio.onAir.opacity(0.18) : Studio.plateSegmentOff
    }
}
