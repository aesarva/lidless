import SwiftUI
import LidlessCore

struct GeneralTab: View {
    @Bindable var controller: SessionController
    let loginItem: LoginItem
    @State private var newPreset = 30

    /// 0 = indefinitely; otherwise preset minutes.
    private var defaultSelection: Binding<Int> {
        Binding {
            if case .minutes(let m) = controller.settings.defaultDuration { return m }
            return 0
        } set: { value in
            controller.settings.defaultDuration = value == 0 ? .indefinite : .minutes(value)
        }
    }

    var body: some View {
        Form {
            Toggle("Launch at login", isOn: Binding(get: { loginItem.isEnabled }, set: { loginItem.isEnabled = $0 }))

            Picker("Default duration", selection: defaultSelection) {
                ForEach(controller.settings.presetMinutes, id: \.self) { m in
                    Text(DurationFormat.label(minutes: m)).tag(m)
                }
                Text("Indefinitely").tag(0)
            }

            Section("Presets") {
                ForEach(controller.settings.presetMinutes, id: \.self) { m in
                    HStack {
                        Text(DurationFormat.label(minutes: m))
                        Spacer()
                        Button {
                            removePreset(m)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .disabled(controller.settings.presetMinutes.count <= 1)
                        .help(String(localized: "Remove preset"))
                    }
                }
                HStack {
                    Stepper(value: $newPreset, in: 5...720, step: 5) {
                        Text(DurationFormat.label(minutes: newPreset))
                    }
                    Button("Add") { addPreset(newPreset) }
                        .disabled(controller.settings.presetMinutes.contains(newPreset))
                }
            }

            Toggle("Show remaining time in menu bar", isOn: $controller.settings.showTimerInMenuBar)
            Toggle("Start a session when Lidless launches", isOn: $controller.settings.startSessionOnLaunch)
        }
        .formStyle(.grouped)
    }

    private func addPreset(_ minutes: Int) {
        let clamped = min(720, max(5, minutes))
        guard !controller.settings.presetMinutes.contains(clamped) else { return }
        controller.settings.presetMinutes = (controller.settings.presetMinutes + [clamped]).sorted()
    }

    private func removePreset(_ minutes: Int) {
        guard controller.settings.presetMinutes.count > 1 else { return }
        controller.settings.presetMinutes.removeAll { $0 == minutes }
        if controller.settings.defaultDuration == .minutes(minutes) {
            controller.settings.defaultDuration = .indefinite
        }
    }
}
