import Foundation

/// What the hooked source is playing, as far as the track keys care.
public enum PlaybackKind: Equatable, Sendable {
    /// Long-form audio where "next" should mean "a bit further".
    case podcast
    /// An explicit list the user is moving through (playlist, album page).
    case tracklist
    case music
    /// The source couldn't say. Treated as music: never guess a seek.
    case unknown
}

/// The source's own skip lengths, in seconds, both positive.
public struct SkipSeconds: Equatable, Sendable {
    public let forward: Int
    public let back: Int

    public init(forward: Int, back: Int) {
        self.forward = forward
        self.back = back
    }

    public static let standard = SkipSeconds(forward: 15, back: 15)
}

public enum TransportAction: Equatable, Sendable {
    case track(MediaCommand)
    /// Signed: negative seeks back.
    case seek(seconds: Int)
}

public enum TransportDecision {
    public static func decide(command: MediaCommand, kind: PlaybackKind, canSeek: Bool,
                              skip: SkipSeconds, skipOnPodcasts: Bool,
                              alwaysSkip: Bool) -> TransportAction {
        guard command != .playPause, canSeek, skipOnPodcasts else { return .track(command) }
        let seeks: Bool
        switch kind {
        case .podcast: seeks = true
        case .tracklist, .music: seeks = alwaysSkip
        case .unknown: seeks = false
        }
        guard seeks else { return .track(command) }
        return .seek(seconds: command == .next ? skip.forward : -skip.back)
    }
}

/// A target that can report what it is playing and jump within it. Every call
/// blocks on the other app, so run them on a `ScriptRunning` queue.
public protocol SeekingMediaApp: MediaApp {
    /// False when this particular target has no way to seek; the keys then keep
    /// their track meaning whatever the settings say.
    var canSeek: Bool { get }
    var skipSeconds: SkipSeconds { get }
    /// True when the app's own skip items decide the length, so the seconds in
    /// `skipSeconds` are only nominal and shouldn't be shown to the user.
    var seeksByMenu: Bool { get }
    func playbackKind() -> PlaybackKind
    func seek(by seconds: Int) -> Bool
}

/// What a routed transport key ended up doing.
public enum RouteOutcome: Equatable, Sendable {
    case notDelivered
    case performed(MediaCommand)
    case skipped(seconds: Int, byMenu: Bool)
}
