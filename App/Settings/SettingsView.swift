import SwiftUI
import LidlessCore

extension SettingsTab {
    /// The toolbar label and the window title while the tab is selected.
    var title: String {
        switch self {
        case .general: String(localized: "General")
        case .safety: String(localized: "Safety")
        case .helper: String(localized: "Helper")
        case .about: String(localized: "About")
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .safety: "shield"
        case .helper: "wrench.and.screwdriver"
        case .about: "info.circle"
        }
    }

    /// The tab's content at the window's width, as tall as its content: the window follows it.
    @MainActor @ViewBuilder
    func content(controller: SessionController, helper: HelperModel, loginItem: LoginItem,
                 updates: any UpdateSource) -> some View {
        switch self {
        case .general: GeneralTab(controller: controller, loginItem: loginItem, updates: updates)
        case .safety: SafetyTab(controller: controller)
        case .helper: HelperTab(controller: controller, helper: helper)
        case .about: AboutTab(updates: updates)
        }
    }
}

extension View {
    /// A form that takes its content's height instead of scrolling, so no tab is ever clipped.
    func fittedForm() -> some View {
        scrollDisabled(true).fixedSize(horizontal: false, vertical: true)
    }
}
