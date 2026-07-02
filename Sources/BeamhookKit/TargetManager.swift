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
        guard let app = currentTargetApp(), app.isRunning else { return }
        app.perform(command)
    }

    /// Nudges the target app's volume up/down by `step` percent (0...100).
    public func stepVolume(up: Bool, step: Int = 6) {
        guard let app = currentTargetApp(), app.isRunning, app.supportsVolume,
              let current = app.currentVolume() else { return }
        let next = min(100, max(0, current + (up ? step : -step)))
        app.setVolume(next)
    }

    /// Whether the current target exposes a scriptable volume.
    public var targetSupportsVolume: Bool {
        currentTargetApp()?.supportsVolume ?? false
    }

    /// Bundle id of the current target, if any.
    public var targetBundleID: String? {
        currentTargetApp()?.bundleID
    }

    private func currentTargetApp() -> MediaApp? {
        guard let id = selectedTargetID else { return nil }
        return resolver.app(withID: id)
    }
}
