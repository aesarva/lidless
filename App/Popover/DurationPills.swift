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

struct DurationPills: View {
    let controller: SessionController
    @State private var showUntil = false
    @State private var untilTime = Date()

    private var selection: SessionDuration? {
        guard let s = controller.session else { return nil }
        guard let end = s.endsAt else { return .indefinite }
        let length = end.timeIntervalSince(s.startedAt)
        for m in controller.settings.presetMinutes where abs(length - TimeInterval(m) * 60) < 1 {
            return .minutes(m)
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Duration")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                ForEach(controller.settings.presetMinutes, id: \.self) { m in
                    Pill(title: DurationFormat.label(minutes: m), selected: selection == .minutes(m)) {
                        apply(.minutes(m))
                    }
                }
                Pill(title: String(localized: "Until…"), selected: false) { showUntil = true }
                    .popover(isPresented: $showUntil, arrowEdge: .bottom) { untilPicker }
                Pill(title: "∞", selected: selection == .indefinite) { apply(.indefinite) }
            }
        }
    }

    private var untilPicker: some View {
        VStack(spacing: 10) {
            DatePicker("", selection: $untilTime, displayedComponents: .hourAndMinute)
                .labelsHidden()
            Button("Start") {
                apply(.until(DurationFormat.nextOccurrence(of: untilTime, now: Date())))
                showUntil = false
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(14)
    }

    private func apply(_ duration: SessionDuration) {
        if controller.session == nil {
            controller.start(duration)
        } else {
            controller.restart(duration)
        }
    }
}

private struct Pill: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: selected ? .semibold : .regular))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .foregroundStyle(selected ? Tile.onAccent : Color.primary)
                .background(Capsule().fill(selected ? Tile.accent : Color.primary.opacity(0.08)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
