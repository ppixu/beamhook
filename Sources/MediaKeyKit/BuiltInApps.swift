import Foundation

public enum BuiltInApps {
    public static let all: [AppDefinition] = [spotify, music, vlc, vox]

    static let spotify = AppDefinition(
        id: "spotify", displayName: "Spotify", bundleID: "com.spotify.client", isBuiltIn: true,
        playPauseScript: "tell application \"Spotify\" to playpause",
        nextScript: "tell application \"Spotify\" to next track",
        previousScript: "tell application \"Spotify\" to previous track",
        volumeScaleKind: .integer(max: 100),
        volumeGetScript: "tell application \"Spotify\" to return sound volume",
        volumeSetScript: "tell application \"Spotify\" to set sound volume to {volume}")

    static let music = AppDefinition(
        id: "music", displayName: "Apple Music", bundleID: "com.apple.Music", isBuiltIn: true,
        playPauseScript: "tell application \"Music\" to playpause",
        nextScript: "tell application \"Music\" to next track",
        previousScript: "tell application \"Music\" to previous track",
        volumeScaleKind: .integer(max: 100),
        volumeGetScript: "tell application \"Music\" to return sound volume",
        volumeSetScript: "tell application \"Music\" to set sound volume to {volume}")

    static let vlc = AppDefinition(
        id: "vlc", displayName: "VLC", bundleID: "org.videolan.vlc", isBuiltIn: true,
        playPauseScript: "tell application \"VLC\" to play",   // toggles play/pause
        nextScript: "tell application \"VLC\" to next",
        previousScript: "tell application \"VLC\" to previous",
        volumeScaleKind: .integer(max: 512),
        volumeGetScript: "tell application \"VLC\" to return audio volume",
        volumeSetScript: "tell application \"VLC\" to set audio volume to {volume}")

    static let vox = AppDefinition(
        id: "vox", displayName: "VOX", bundleID: "com.coppertino.Vox", isBuiltIn: true,
        playPauseScript: "tell application \"VOX\" to playpause",
        nextScript: "tell application \"VOX\" to next track",
        previousScript: "tell application \"VOX\" to previous track",
        volumeScaleKind: .unitFloat,
        volumeGetScript: "tell application \"VOX\" to return player volume",
        volumeSetScript: "tell application \"VOX\" to set player volume to {volume}")
}
