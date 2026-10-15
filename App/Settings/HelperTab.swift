import SwiftUI
import WakeUpCore

struct HelperTab: View {
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
                    Button("Install…") { run { await helper.install() } }
                    Button("Uninstall…") { run { await helper.uninstall() } }
                    if helper.isWorking { ProgressView().controlSize(.small) }
                }
                .disabled(helper.isWorking)
                if let errorText {
                    Text(errorText).foregroundStyle(.red).font(.caption)
                }
            }
            Section {
                Text("Closed-lid mode needs a one-time administrator password to allow WakeUp to run exactly one command: pmset disablesleep. A background watchdog restores normal sleep if WakeUp quits unexpectedly.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func run(_ work: @escaping () async -> HelperError?) {
        errorText = nil
        Task {
            guard let error = await work() else { return }
            switch error {
            case .cancelled: break
            case .invalidUserName(let m), .commandFailed(let m), .installFailed(let m): errorText = m
            }
        }
    }
}
