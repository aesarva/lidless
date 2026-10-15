import Foundation

@MainActor public final class UserDefaultsSettingsStore: SettingsStore {
    static let key = "settings.v1"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> LidlessSettings {
        guard let data = defaults.data(forKey: Self.key),
              let settings = try? JSONDecoder().decode(LidlessSettings.self, from: data) else {
            return LidlessSettings()
        }
        return settings
    }

    public func save(_ s: LidlessSettings) {
        guard let data = try? JSONEncoder().encode(s) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
