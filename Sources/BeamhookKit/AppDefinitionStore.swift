import Foundation

public final class AppDefinitionStore {
    private let defaults: UserDefaults
    private let key = "userDefinedApps"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func loadUserDefined() -> [AppDefinition] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([AppDefinition].self, from: data)) ?? []
    }

    public func saveUserDefined(_ defs: [AppDefinition]) {
        if let data = try? JSONEncoder().encode(defs) {
            defaults.set(data, forKey: key)
        }
    }

    /// Built-ins first, then user-defined.
    public func allDefinitions() -> [AppDefinition] {
        BuiltInApps.all + loadUserDefined()
    }
}
