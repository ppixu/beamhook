import Foundation

/// Whether the track keys short-skip on podcasts, and whether they always do.
///
/// Skipping on podcasts is on when absent: a "next" press on an episode almost
/// never means "throw this episode away". Always-skip is opt-in because it takes
/// next/previous track away from music.
public enum TrackKeyPreference {
    public static let skipOnPodcastsKey = "skipOnPodcasts"
    public static let alwaysSkipKey = "alwaysSkip"

    public static func skipOnPodcasts(_ defaults: UserDefaults) -> Bool {
        defaults.object(forKey: skipOnPodcastsKey) as? Bool ?? true
    }

    public static func alwaysSkip(_ defaults: UserDefaults) -> Bool {
        defaults.object(forKey: alwaysSkipKey) as? Bool ?? false
    }

    public static func setSkipOnPodcasts(_ enabled: Bool, in defaults: UserDefaults) {
        defaults.set(enabled, forKey: skipOnPodcastsKey)
    }

    public static func setAlwaysSkip(_ enabled: Bool, in defaults: UserDefaults) {
        defaults.set(enabled, forKey: alwaysSkipKey)
    }
}
