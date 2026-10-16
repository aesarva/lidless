import SwiftUI
import LidlessCore

enum DurationFormat {
    /// Minutes < 60 -> "15 min"; multiples of 60 -> "3 h"; otherwise "1 h 30 min".
    static func label(minutes: Int) -> String {
        if minutes < 60 { return String(localized: "\(minutes) min") }
        if minutes % 60 == 0 { return String(localized: "\(minutes / 60) h") }
        return String(localized: "\(minutes / 60) h \(minutes % 60) min")
    }

    /// Next occurrence of the picked wall-clock time; earlier-than-now means tomorrow.
    static func nextOccurrence(of picked: Date, now: Date, calendar: Calendar = .current) -> Date {
        let comps = calendar.dateComponents([.hour, .minute], from: picked)
        return calendar.nextDate(
            after: now, matching: DateComponents(hour: comps.hour, minute: comps.minute, second: 0),
            matchingPolicy: .nextTime
        ) ?? now.addingTimeInterval(86_400)
    }
}

/// Session length as a native segmented control: presets, "Until…" (a time picker) and ∞.
/// Picking a segment starts a session, or restarts the running one with the new length.
struct DurationPicker: View {
    let controller: SessionController
    @State private var showUntil = false
    @State private var untilTime = Date()

    private enum Choice: Hashable { case preset(Int), until, indefinite }

    private var current: Choice? {
        guard let s = controller.session else { return nil }
        guard let end = s.endsAt else { return .indefinite }
        let length = end.timeIntervalSince(s.startedAt)
        for m in controller.settings.presetMinutes where abs(length - TimeInterval(m) * 60) < 1 {
            return .preset(m)
        }
        return .until
    }

    var body: some View {
        let items: [(Choice, String)] = controller.settings.presetMinutes.map { (.preset($0), DurationFormat.label(minutes: $0)) }
            + [(.until, String(localized: "Until…")), (.indefinite, "∞")]
        HStack(spacing: 2) {
            ForEach(items, id: \.0) { choice, title in
                Segment(title: title, selected: current == choice) { pick(choice) }
                    .accessibilityLabel(choice == .indefinite ? Text("Indefinitely") : Text(title))
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Studio.raised))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Duration"))
        .popover(isPresented: $showUntil, arrowEdge: .bottom) { untilPicker }
    }

    private var untilPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Stay awake until")
                .font(.system(size: 12, weight: .semibold))
            DatePicker("", selection: $untilTime, displayedComponents: .hourAndMinute)
                .labelsHidden()
                .datePickerStyle(.stepperField)
            Button("Start") {
                apply(.until(DurationFormat.nextOccurrence(of: untilTime, now: Date())))
                showUntil = false
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(14)
    }

    private func pick(_ choice: Choice?) {
        switch choice {
        case .preset(let m)?: apply(.minutes(m))
        case .indefinite?: apply(.indefinite)
        case .until?:
            untilTime = controller.session?.endsAt ?? Date().addingTimeInterval(3600)
            showUntil = true
        case nil: break
        }
    }

    private func apply(_ duration: SessionDuration) {
        if controller.session == nil {
            controller.start(duration)
        } else {
            controller.restart(duration)
        }
    }
}

/// One segment of the duration control: equal share of the width, cream when selected.
private struct Segment: View {
    let title: String
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: selected ? .semibold : .regular))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .foregroundStyle(selected ? Studio.plateInk : Studio.ink)
                .frame(maxWidth: .infinity, minHeight: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(selected ? Studio.plate : (hovering ? Studio.ink.opacity(0.08) : .clear))
                )
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
        .animation(.easeOut(duration: 0.15), value: selected)
    }
}
