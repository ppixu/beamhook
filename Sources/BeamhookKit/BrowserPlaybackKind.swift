import Foundation

/// What a page told us about its media at key-press time. Decoded from the JSON
/// `BrowserMediaController.transportFacts` returns; `host` has `www.` stripped.
public struct BrowserPlaybackFacts: Equatable, Sendable, Decodable {
    public enum NextButton: String, Decodable, Sendable {
        case enabled, disabled, absent
    }

    public let host: String
    /// nil for live streams and media that hasn't loaded a length.
    public let duration: Double?
    /// YouTube's `list=` — the video is part of a playlist.
    public let hasListParam: Bool
    /// YouTube's or Bandcamp's own next button.
    public let nextButton: NextButton
    public let live: Bool

    public init(host: String, duration: Double?, hasListParam: Bool,
                nextButton: NextButton, live: Bool) {
        self.host = host
        self.duration = duration
        self.hasListParam = hasListParam
        self.nextButton = nextButton
        self.live = live
    }
}

public enum BrowserPlaybackKind {
    /// Twenty minutes: past every song and most music videos, short of most
    /// podcast episodes and talks.
    public static let longFormSeconds: Double = 20 * 60

    public static func classify(_ facts: BrowserPlaybackFacts) -> PlaybackKind {
        if facts.live { return .music }
        // A list the user chose to move through wins over length.
        if isYouTube(host: facts.host), facts.hasListParam, facts.nextButton == .enabled {
            return .tracklist
        }
        if isBandcamp(host: facts.host), facts.nextButton == .enabled { return .tracklist }
        if let duration = facts.duration, duration.isFinite, duration >= longFormSeconds {
            return .podcast
        }
        // Nothing for "next" to reach: a short skip beats a dead key.
        if facts.nextButton != .enabled { return .podcast }
        return .music
    }

    public static func canSeek(_ facts: BrowserPlaybackFacts) -> Bool {
        guard !facts.live, let duration = facts.duration else { return false }
        return duration.isFinite && duration > 0
    }

    /// YouTube's own J/L keys jump 10 s; elsewhere use the common 15 s.
    public static func skipSeconds(host: String) -> SkipSeconds {
        isYouTube(host: host) ? SkipSeconds(forward: 10, back: 10) : .standard
    }

    public static func isYouTube(host: String) -> Bool {
        host == "youtube.com" || host.hasSuffix(".youtube.com") || host == "youtu.be"
    }

    static func isBandcamp(host: String) -> Bool {
        host == "bandcamp.com" || host.hasSuffix(".bandcamp.com")
    }
}
