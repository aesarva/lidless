import AppKit
import Observation

/// The app's own UI language, independent of the system list. Stored as `AppleLanguages`
/// in Lidless's defaults domain, which macOS reads at launch, so a change applies on restart.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system, ru, en

    var id: String { rawValue }

    /// Native names, so each choice is readable whatever the current UI language.
    var title: String {
        switch self {
        case .system: String(localized: "Same as system")
        case .ru: "Русский"
        case .en: "English"
        }
    }

    /// The choice saved in Lidless's own defaults (not the global language list).
    static var saved: AppLanguage {
        let domain = Bundle.main.bundleIdentifier.flatMap { UserDefaults.standard.persistentDomain(forName: $0) }
        guard let first = (domain?["AppleLanguages"] as? [String])?.first else { return .system }
        return AppLanguage(rawValue: String(first.prefix(2))) ?? .system
    }

    func save() {
        if self == .system {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([rawValue], forKey: "AppleLanguages")
        }
    }
}

@MainActor @Observable final class LanguageModel {
    /// What this process launched with; the UI shows it until a restart.
    private let launched = AppLanguage.saved
    var selection = AppLanguage.saved {
        didSet { selection.save() }
    }

    var needsRestart: Bool { selection != launched }

    /// Quits and reopens Lidless so macOS loads the chosen language. A running session
    /// ends normally first (the Mac goes back to its usual sleep settings).
    func restart() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", path]
        try? task.run()
        NSApp.terminate(nil)
    }
}
