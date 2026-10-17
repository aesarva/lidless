import SwiftUI
import LidlessCore

struct HelperTab: View {
    let controller: SessionController
    let helper: HelperModel
    @State private var errorText: String?

    var body: some View {
        Form {
            Section {
                LabeledContent("Status") {
                    switch helper.status {
                    case .notInstalled: Text("Not installed")
                    case .installed: Text("Installed")
                    case .error(let message): Text("Error: \(message)").foregroundStyle(.red)
                    }
                }
                HStack {
                    Button("Install…") {
                        run({ await helper.install() }, onSuccess: { controller.helperDidChange() })
                    }
                    Button("Uninstall…") {
                        // Turn lid mode off while the helper can still do it; the setting stays
                        // off, so nothing turns it back on while the uninstall runs.
                        let lidWasOn = controller.settings.lidModeEnabled
                        controller.setLidMode(false)
                        run({ await helper.uninstall() },
                            onSuccess: { controller.helperDidChange() },
                            onCancel: { if lidWasOn { controller.setLidMode(true) } })
                    }
                    if helper.isWorking { ProgressView().controlSize(.small) }
                }
                .disabled(helper.isWorking)
                if let errorText {
                    Text(errorText).foregroundStyle(.red).font(.caption)
                }
            }
            Section {
                Text("Closed-lid mode needs a one-time administrator password to allow Lidless to run exactly one command: pmset disablesleep. A background watchdog restores normal sleep if Lidless quits unexpectedly.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func run(_ work: @escaping () async -> HelperError?, onSuccess: @escaping () -> Void = {},
                     onCancel: @escaping () -> Void = {}) {
        errorText = nil
        Task {
            guard let error = await work() else {
                onSuccess()
                return
            }
            switch error {
            case .cancelled: onCancel()
            case .invalidUserName(let m), .commandFailed(let m), .installFailed(let m): errorText = m
            }
        }
    }
}
