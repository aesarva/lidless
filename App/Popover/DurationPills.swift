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
        Picker("Duration", selection: Binding<Choice?>(get: { current }, set: { pick($0) })) {
            ForEach(controller.settings.presetMinutes, id: \.self) { m in
                Text(DurationFormat.label(minutes: m)).tag(Choice?.some(.preset(m)))
            }
            Text("Until…").tag(Choice?.some(.until))
            Text("∞").tag(Choice?.some(.indefinite))
                .accessibilityLabel(Text("Indefinitely"))
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .tint(Studio.plate) // cream selection, as on the meter plate; never the system blue
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
