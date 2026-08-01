import Foundation

/// Whether a hooked play/pause press flashes the on-screen overlay.
public enum PlayPauseHUDPreference {
    public static let storageKey = "showPlayPauseHUD"

    /// Absent means ON. A play/pause press gives no other feedback that it
    /// reached the hooked app rather than whatever the system would have
    /// picked — which is the whole point of hooking it. Someone who finds the
    /// confirmation redundant can turn it off in Settings.
    public static func isEnabled(_ defaults: UserDefaults) -> Bool {
        defaults.object(forKey: storageKey) as? Bool ?? true
    }

    public static func setEnabled(_ enabled: Bool, in defaults: UserDefaults) {
        defaults.set(enabled, forKey: storageKey)
    }
}
