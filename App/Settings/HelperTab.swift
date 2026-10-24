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
                    case .checking: Text("Checking…")
                    case .installed:
                        if let info = helper.daemonInfo {
                            Text("Running — version \(info.version) (build \(info.build))")
                        } else {
                            Text("Running, version \(Bundle.main.shortVersion)")
                        }
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
                    .disabled([HelperStatus.installed, .checking, .needsApproval, .unsigned].contains(helper.status))
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

    /// Turns lid mode off while the helper can still do it, and removes the helper only once
    /// the daemon has confirmed that normal sleep is back; until the removal ends lid mode
    /// cannot be taken again. If the release is not confirmed or the removal fails, lid mode
    /// comes back as it was, through the safety check.
    private func remove() {
        errorText = nil
        helper.beginRemoval()
        controller.beginHelperRemoval { point, released in
            guard released else {
                errorText = String(localized: "Couldn't restore normal sleep — the helper was not removed.")
                controller.restoreAfterFailedRemoval(point)
                controller.endHelperRemoval()
                helper.endRemoval()
                return
            }
            Task {
                if let error = await helper.uninstall() {
                    errorText = error.message
                    controller.restoreAfterFailedRemoval(point)
                } else {
                    controller.helperDidChange()
                }
                controller.endHelperRemoval()
                helper.endRemoval()
            }
        }
    }

    private func run(_ work: @escaping () async -> HelperError?) {
        errorText = nil
        Task {
            if let error = await work() { errorText = error.message }
        }
    }
}
