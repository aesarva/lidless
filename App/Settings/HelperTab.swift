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
                    // Until the Task 7 UI: waiting for approval and unsigned read as not installed.
                    case .notInstalled, .needsApproval, .unsigned: Text("Not installed")
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
                        controller.setLidMode(false)
                        run({ await helper.uninstall() }, onSuccess: { controller.helperDidChange() })
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

    private func run(_ work: @escaping () async -> HelperError?, onSuccess: @escaping () -> Void = {}) {
        errorText = nil
        Task {
            guard let error = await work() else {
                onSuccess()
                return
            }
            errorText = error.message
        }
    }
}
