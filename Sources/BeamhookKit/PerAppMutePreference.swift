import Foundation

/// Whether the per-app mute buttons are available, and which apps are muted.
///
/// Muting works through a macOS system-audio tap (`CATapDescription` with the
/// muted behavior), which requires the System Audio Recording permission — so
/// the feature is OFF until the user explicitly enables it in Settings and the
/// permission flow runs. The muted set persists so a mute survives Beamhook
/// restarts; turning the feature off clears it, keeping "disabled" a clean
/// slate rather than a dormant state that could resurface much later.
public enum PerAppMutePreference {
    public static let enabledKey = "perAppMuteEnabled"
    public static let mutedAppsKey = "perAppMutedBundleIDs"

    /// Absent means OFF.
    public static func isEnabled(_ defaults: UserDefaults) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? false
    }

    public static func setEnabled(_ enabled: Bool, in defaults: UserDefaults) {
        defaults.set(enabled, forKey: enabledKey)
        if !enabled {
            defaults.removeObject(forKey: mutedAppsKey)
        }
    }

    public static func mutedBundleIDs(_ defaults: UserDefaults) -> Set<String> {
        Set(defaults.stringArray(forKey: mutedAppsKey) ?? [])
    }

    public static func setMutedBundleIDs(_ ids: Set<String>, in defaults: UserDefaults) {
        if ids.isEmpty {
            defaults.removeObject(forKey: mutedAppsKey)
        } else {
            defaults.set(ids.sorted(), forKey: mutedAppsKey)
        }
    }
}
