import Foundation

/// Whether headphone buttons (AirPods, Bluetooth headsets) reach the hooked app.
///
/// Those buttons never produce the keyboard's system-defined events, so the
/// media-key tap can't see them: macOS hands them straight to whichever app
/// owns Now Playing. Routing them means Beamhook claiming Now Playing itself.
public enum HeadphoneControlPreference {
    public static let storageKey = "routeHeadphoneControls"

    /// Absent means ON: a headphone press reaching some other app is the same
    /// hijack the keyboard routing exists to prevent.
    public static func isEnabled(_ defaults: UserDefaults) -> Bool {
        defaults.object(forKey: storageKey) as? Bool ?? true
    }

    public static func setEnabled(_ enabled: Bool, in defaults: UserDefaults) {
        defaults.set(enabled, forKey: storageKey)
    }
}

/// A remote command macOS delivers to the Now Playing app.
public enum HeadphoneCommand: Equatable, Sendable {
    case play, pause, togglePlayPause, next, previous

    /// Explicit play/pause (sent e.g. when an AirPod goes in or out of an ear)
    /// map onto a toggle only when the target's state makes it the right one.
    public var needsPlayState: Bool {
        self == .play || self == .pause
    }

    /// The key to route, or nil when the command should do nothing. An
    /// explicit pause with unknown state is dropped: taking an AirPod out must
    /// never start playback.
    public func key(targetPlaying: Bool?) -> MediaKey? {
        switch self {
        case .togglePlayPause: return .playPause
        case .next:            return .next
        case .previous:        return .previous
        case .play:            return targetPlaying == true ? nil : .playPause
        case .pause:           return targetPlaying == true ? .playPause : nil
        }
    }
}

public enum NowPlayingClaimDecision {
    /// Claim Now Playing only while the keyboard's transport keys are hooked
    /// too, so headphones and keyboard always reach the same place.
    public static func shouldClaim(enabled: Bool, hasTarget: Bool, transportHijacked: Bool) -> Bool {
        enabled && hasTarget && transportHijacked
    }
}
