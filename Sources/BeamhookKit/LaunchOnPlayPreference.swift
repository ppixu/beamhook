import Foundation

/// Whether a play/pause press may start the hooked app when it isn't running.
public enum LaunchOnPlayPreference {
    public static let storageKey = "launchTargetOnPlay"

    /// Absent means ON. Unlike the volume-key hijack — which silently takes a
    /// working system key away and so must be opted into — this only fills a
    /// press that currently does nothing at all.
    public static func isEnabled(_ defaults: UserDefaults) -> Bool {
        defaults.object(forKey: storageKey) as? Bool ?? true
    }

    public static func setEnabled(_ enabled: Bool, in defaults: UserDefaults) {
        defaults.set(enabled, forKey: storageKey)
    }
}
