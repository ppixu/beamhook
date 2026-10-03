import Foundation

/// Whether the per-app mute buttons are available, and which apps are muted.
///
/// Muting works through a macOS system-audio tap (`CATapDescription` with the
/// muted behavior), which requires the System Audio Recording permission. The
/// feature is ON by default — the buttons are the point of the menu for apps
/// Beamhook can't otherwise control — and the app asks for the permission once
/// at first launch, right after Accessibility. The muted set persists so a
/// mute survives Beamhook restarts; turning the feature off clears it, keeping
/// "disabled" a clean slate rather than a dormant state that could resurface
/// much later.
public enum PerAppMutePreference {
    public static let enabledKey = "perAppMuteEnabled"
    public static let mutedAppsKey = "perAppMutedBundleIDs"
    public static let volumesKey = "perAppVolumes"

    /// Absent means ON.
    public static func isEnabled(_ defaults: UserDefaults) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? true
    }

    public static func setEnabled(_ enabled: Bool, in defaults: UserDefaults) {
        defaults.set(enabled, forKey: enabledKey)
        if !enabled {
            defaults.removeObject(forKey: mutedAppsKey)
            defaults.removeObject(forKey: volumesKey)
        }
    }

    /// Only attenuated levels are persisted; absence means normal (100%).
    public static func volumes(_ defaults: UserDefaults) -> [String: Int] {
        (defaults.dictionary(forKey: volumesKey) as? [String: Int] ?? [:])
            .mapValues { min(100, max(0, $0)) }.filter { $0.value < 100 }
    }

    public static func setVolumes(_ volumes: [String: Int], in defaults: UserDefaults) {
        let values = volumes.mapValues { min(100, max(0, $0)) }.filter { $0.value < 100 }
        if values.isEmpty { defaults.removeObject(forKey: volumesKey) }
        else { defaults.set(values, forKey: volumesKey) }
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
