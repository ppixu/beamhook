import Foundation

public final class TargetManager {
    private let defaults: UserDefaults
    private let resolver: MediaAppResolver
    private static let storageKey = "selectedTargetAppID"

    public init(defaults: UserDefaults, resolver: MediaAppResolver) {
        self.defaults = defaults
        self.resolver = resolver
    }

    public var selectedTargetID: String? {
        get { defaults.string(forKey: Self.storageKey) }
        set {
            if let newValue { defaults.set(newValue, forKey: Self.storageKey) }
            else { defaults.removeObject(forKey: Self.storageKey) }
        }
    }

    /// Routes a media key to the selected target. No-op for non-command keys,
    /// no selected target, or a target that isn't running.
    public func handle(_ key: MediaKey) {
        guard let command = key.command else { return }
        guard let id = selectedTargetID,
              let app = resolver.app(withID: id),
              app.isRunning else { return }
        app.perform(command)
    }
}
