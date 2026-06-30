import Foundation

public enum BuiltInApps {
    public static let all: [AppDefinition] = [spotify, music, appleTV, vlc, vox, quickTime, swinsian, downcast]

    public static let spotify = AppDefinition(
        id: "spotify", displayName: "Spotify", bundleID: "com.spotify.client", isBuiltIn: true,
        playPauseScript: "tell application \"Spotify\" to playpause",
        nextScript: "tell application \"Spotify\" to next track",
        previousScript: "tell application \"Spotify\" to previous track",
        volumeScaleKind: .integer(max: 100),
        volumeGetScript: "tell application \"Spotify\" to return sound volume",
        volumeSetScript: "tell application \"Spotify\" to set sound volume to {volume}",
        playStateScript: "tell application \"Spotify\" to return (player state as text)")

    public static let music = AppDefinition(
        id: "music", displayName: "Apple Music", bundleID: "com.apple.Music", isBuiltIn: true,
        playPauseScript: "tell application \"Music\" to playpause",
        nextScript: "tell application \"Music\" to next track",
        previousScript: "tell application \"Music\" to previous track",
        volumeScaleKind: .integer(max: 100),
        volumeGetScript: "tell application \"Music\" to return sound volume",
        volumeSetScript: "tell application \"Music\" to set sound volume to {volume}",
        playStateScript: "tell application \"Music\" to return (player state as text)")

    public static let vlc = AppDefinition(
        id: "vlc", displayName: "VLC", bundleID: "org.videolan.vlc", isBuiltIn: true,
        playPauseScript: "tell application \"VLC\" to play",   // toggles play/pause
        nextScript: "tell application \"VLC\" to next",
        previousScript: "tell application \"VLC\" to previous",
        volumeScaleKind: .integer(max: 512),
        volumeGetScript: "tell application \"VLC\" to return audio volume",
        volumeSetScript: "tell application \"VLC\" to set audio volume to {volume}",
        playStateScript: "tell application \"VLC\" to return (playing as text)")

    public static let vox = AppDefinition(
        id: "vox", displayName: "VOX", bundleID: "com.coppertino.Vox", isBuiltIn: true,
        playPauseScript: "tell application \"VOX\" to playpause",
        nextScript: "tell application \"VOX\" to next track",
        previousScript: "tell application \"VOX\" to previous track",
        volumeScaleKind: .unitFloat,
        volumeGetScript: "tell application \"VOX\" to return player volume",
        volumeSetScript: "tell application \"VOX\" to set player volume to {volume}")

    // Apple TV app — shares Music's "iTunes Suite" scripting terminology
    // (verified against /System/Applications/TV.app's scripting dictionary).
    public static let appleTV = AppDefinition(
        id: "appleTV", displayName: "Apple TV", bundleID: "com.apple.TV", isBuiltIn: true,
        playPauseScript: "tell application \"TV\" to playpause",
        nextScript: "tell application \"TV\" to next track",
        previousScript: "tell application \"TV\" to previous track",
        volumeScaleKind: .integer(max: 100),
        volumeGetScript: "tell application \"TV\" to return sound volume",
        volumeSetScript: "tell application \"TV\" to set sound volume to {volume}",
        playStateScript: "tell application \"TV\" to return (player state as text)")

    // QuickTime Player has play/pause/stop verbs and a `playing` property, but no
    // `playpause` toggle and no playlist — so play/pause is synthesized from state,
    // and there is no next/previous. (Verified against its scripting dictionary.)
    public static let quickTime = AppDefinition(
        id: "quicktime", displayName: "QuickTime Player", bundleID: "com.apple.QuickTimePlayerX", isBuiltIn: true,
        playPauseScript: "tell application \"QuickTime Player\" to if playing of document 1 then pause document 1 else play document 1",
        nextScript: nil,
        previousScript: nil,
        volumeScaleKind: .none,
        volumeGetScript: nil,
        volumeSetScript: nil,
        playStateScript: "tell application \"QuickTime Player\" to return (playing of document 1) as text")

    // Swinsian (Potion Factory) — full iTunes-style dictionary: playpause, next/
    // previous track, player state, sound volume 0–100.
    public static let swinsian = AppDefinition(
        id: "swinsian", displayName: "Swinsian", bundleID: "com.potionfactory.Swinsian", isBuiltIn: true,
        playPauseScript: "tell application \"Swinsian\" to playpause",
        nextScript: "tell application \"Swinsian\" to next track",
        previousScript: "tell application \"Swinsian\" to previous track",
        volumeScaleKind: .integer(max: 100),
        volumeGetScript: "tell application \"Swinsian\" to return sound volume",
        volumeSetScript: "tell application \"Swinsian\" to set sound volume to {volume}",
        playStateScript: "tell application \"Swinsian\" to return (player state as text)")

    // Downcast (podcasts) — playpause/next/previous; play state from now-playing info.
    public static let downcast = AppDefinition(
        id: "downcast", displayName: "Downcast", bundleID: "com.jamawkinaw.downcast.mac", isBuiltIn: true,
        playPauseScript: "tell application \"Downcast\" to playpause",
        nextScript: "tell application \"Downcast\" to next",
        previousScript: "tell application \"Downcast\" to previous",
        volumeScaleKind: .none,
        volumeGetScript: nil,
        volumeSetScript: nil,
        playStateScript: "tell application \"Downcast\" to return (is playing of now playing info) as text")
}
