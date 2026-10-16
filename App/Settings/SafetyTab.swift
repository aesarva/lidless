import SwiftUI
import LidlessCore

struct SafetyTab: View {
    @Bindable var controller: SessionController

    private var threshold: Binding<Double> {
        Binding {
            Double(controller.settings.safety.batteryThreshold)
        } set: {
            controller.settings.safety.batteryThreshold = min(50, max(5, Int(($0 / 5).rounded()) * 5))
        }
    }

    var body: some View {
        Form {
            Section {
                Toggle("Turn off on low battery", isOn: $controller.settings.safety.batteryRuleEnabled)
                HStack {
                    Slider(value: threshold, in: 5...50, step: 5)
                    Text("\(controller.settings.safety.batteryThreshold)%")
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }
                .disabled(!controller.settings.safety.batteryRuleEnabled)
            }
            Section {
                Toggle("Turn off when the Mac overheats", isOn: $controller.settings.safety.thermalRuleEnabled)
                Text("Triggers when macOS reports serious or critical thermal pressure.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Limit closed-lid time", isOn: $controller.settings.safety.lidLimitRuleEnabled)
                Stepper(
                    value: $controller.settings.safety.lidLimitMinutes, in: 30...720, step: 30
                ) {
                    Text(DurationFormat.label(minutes: controller.settings.safety.lidLimitMinutes))
                }
                .disabled(!controller.settings.safety.lidLimitRuleEnabled)
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
    }
}
