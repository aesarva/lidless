import SwiftUI
import LidlessCore

@MainActor @Observable
final class SettingsNavigation {
    var tab: SettingsTab = .general
}

extension SettingsTab: Hashable {}

struct SettingsView: View {
    let controller: SessionController
    let helper: HelperModel
    let loginItem: LoginItem
    @Bindable var navigation: SettingsNavigation

    var body: some View {
        TabView(selection: $navigation.tab) {
            GeneralTab(controller: controller, loginItem: loginItem)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            SafetyTab(controller: controller)
                .tabItem { Label("Safety", systemImage: "shield") }
                .tag(SettingsTab.safety)
            HelperTab(controller: controller, helper: helper)
                .tabItem { Label("Helper", systemImage: "wrench.and.screwdriver") }
                .tag(SettingsTab.helper)
            AboutTab()
                .tabItem { Label("About", systemImage: "info.circle") }
                .tag(SettingsTab.about)
        }
        .padding(20)
        .frame(width: 480, height: 400)
    }
}
