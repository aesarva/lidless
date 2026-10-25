import SwiftUI
import LidlessCore

struct GeneralTab: View {
    @Bindable var controller: SessionController
    let loginItem: LoginItem
    let updates: any UpdateSource
    @State private var newPreset = 30
    @State private var language = LanguageModel()

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
            Section {
                Picker("Language", selection: $language.selection) {
                    ForEach(AppLanguage.allCases) { Text($0.title).tag($0) }
                }
                if language.needsRestart {
                    HStack {
                        Text("Lidless restarts to switch the language; a running session ends.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Restart Lidless") { language.restart() }
                    }
                }
            }

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

            Section("Updates") {
                Toggle("Check for updates automatically", isOn: Binding(
                    get: { updates.automaticallyChecks }, set: { updates.automaticallyChecks = $0 }))
                HStack(alignment: .firstTextBaseline) {
                    if let status = updateStatus {
                        Text(status)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button("Check Now") { updates.checkNow() }
                        .disabled(updateBusy || !updates.canCheckNow)
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// No manual check while an update is under way, or from a copy Sparkle cannot update.
    private var updateBusy: Bool {
        switch updates.state {
        case .checking, .downloading, .installing, .waitingForLid, .needsMove: true
        case .idle, .upToDate, .available, .failed: false
        }
    }

    /// The result of the last check, in the panel's words; "up to date" is shown only here.
    private var updateStatus: String? {
        switch updates.state {
        case .idle: nil
        case .checking: String(localized: "Checking for updates…")
        case .upToDate: String(localized: "You have the latest version")
        case .available(let version, _): String(localized: "Version \(version) available")
        case .downloading(let version, _): String(localized: "Downloading \(version)")
        case .installing: String(localized: "Installing…")
        case .waitingForLid: String(localized: "Installs when you open the lid")
        case .failed(let message): String(localized: "Couldn't update: \(message)")
        case .needsMove: String(localized: "Move Lidless to Applications to keep it updated")
        }
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
