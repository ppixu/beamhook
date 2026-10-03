import Foundation

/// Whether holding Command while pressing a volume key reaches the hooked app
/// instead of the system.
public enum CommandVolumePreference {
    public static let storageKey = "commandVolumeRouting"

    /// Absent means ON. Unlike the per-app volume hijack — which takes a working
    /// system key away outright and so must be opted into — this only fills a
    /// chord that does nothing today: macOS assigns no meaning to Command plus a
    /// volume key. The plain keys keep working exactly as they did.
    public static func isEnabled(_ defaults: UserDefaults) -> Bool {
        defaults.object(forKey: storageKey) as? Bool ?? true
    }

    public static func setEnabled(_ enabled: Bool, in defaults: UserDefaults) {
        defaults.set(enabled, forKey: storageKey)
    }
}
