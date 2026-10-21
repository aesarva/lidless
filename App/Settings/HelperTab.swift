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
                    case .notInstalled: Text("Not set up")
                    case .needsApproval: Text("Waiting for approval")
                    case .installed: Text("Running, version \(Bundle.main.shortVersion)")
                    case .unsigned: Text("Needs a signed build")
                    case .error(let message): Text("Error: \(message)").foregroundStyle(.red)
                    }
                }
                if helper.status == .needsApproval {
                    Button("Open System Settings…") { helper.openSystemSettings() }
                }
                HStack {
                    Button("Set Up…") {
                        // HelperModel.onBecameInstalled tells the controller once it is allowed.
                        run { await helper.install() }
                    }
                    .disabled([HelperStatus.installed, .needsApproval, .unsigned].contains(helper.status))
                    Button("Remove") { remove() }
                        .disabled(helper.status == .notInstalled || helper.status == .unsigned)
                    if helper.isWorking { ProgressView().controlSize(.small) }
                }
                .disabled(helper.isWorking)
                if helper.legacyRemoved {
                    Text("The 0.2.0 helper was removed.").font(.caption).foregroundStyle(.secondary)
                } else if let legacyError = helper.legacyError {
                    Text("Couldn't remove the 0.2.0 helper: \(legacyError)").font(.caption).foregroundStyle(.red)
                }
                if let errorText {
                    Text(errorText).foregroundStyle(.red).font(.caption)
                }
            }
            Section {
                Text("Closed-lid mode uses a small background helper that can do one thing: turn pmset disablesleep on and off. It accepts commands only from Lidless signed by the same developer, needs no password, and restores normal sleep the moment Lidless quits or crashes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Turns lid mode off while the helper can still do it; the setting stays off, so nothing
    /// turns it back on while the removal runs. If the removal fails, only the setting comes
    /// back: lid mode is not acquired again behind the safety rules.
    private func remove() {
        let wasEnabled = controller.settings.lidModeEnabled
        controller.setLidMode(false)
        run({ await helper.uninstall() },
            onSuccess: { controller.helperDidChange() },
            onFailure: { controller.restoreLidModePreference(wasEnabled) })
    }

    private func run(_ work: @escaping () async -> HelperError?,
                     onSuccess: @escaping () -> Void = {}, onFailure: @escaping () -> Void = {}) {
        errorText = nil
        Task {
            guard let error = await work() else {
                onSuccess()
                return
            }
            errorText = error.message
            onFailure()
        }
    }
}
