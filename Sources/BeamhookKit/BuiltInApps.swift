import Foundation

public enum BuiltInApps {
    public static let all: [AppDefinition] = [
        spotify, music, appleTV, safariYouTube, chromeYouTube, braveYouTube,
        arcYouTube, vivaldiYouTube, vlc, vox, quickTime, downcast,
    ]

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

    // Browser scripting must be enabled by the user. Safari exposes this under
    // Develop > Allow JavaScript from Apple Events; Chromium browsers expose it
    // under View > Developer > Allow JavaScript from Apple Events.
    public static let safariYouTube = browserDefinition(
        id: "safari-youtube", displayName: "Safari", bundleID: "com.apple.Safari",
        script: safariScript)

    public static let chromeYouTube = browserDefinition(
        id: "chrome-youtube", displayName: "Chrome", bundleID: "com.google.Chrome",
        script: { chromiumScript(application: "Google Chrome", javascript: $0) })

    public static let braveYouTube = browserDefinition(
        id: "brave-youtube", displayName: "Brave", bundleID: "com.brave.Browser",
        script: { chromiumScript(application: "Brave Browser", javascript: $0) })

    public static let arcYouTube = browserDefinition(
        id: "arc-youtube", displayName: "Arc", bundleID: "company.thebrowser.Browser",
        script: { chromiumScript(application: "Arc", javascript: $0) })

    public static let vivaldiYouTube = browserDefinition(
        id: "vivaldi-youtube", displayName: "Vivaldi", bundleID: "com.vivaldi.Vivaldi",
        script: { chromiumScript(application: "Vivaldi", javascript: $0) })

    // A call/conference tab (`p.live`) has no transport to drive — pausing a live
    // MediaStream would just freeze the user's view of the meeting — so the
    // transport and play-state scripts decline it. This is the backstop: the UI
    // hides those controls, but a stale selection must not reach a call either.
    private static let playPauseJS = """
        (() => { \(BrowserJS.pick) const p = bhPick(); if (!p || p.live) return false; const youtube = document.querySelector('.ytp-play-button'); if (youtube) youtube.click(); else if (p.el.paused) void p.el.play(); else p.el.pause(); return true; })()
        """
    private static let nextJS = """
        (() => { const b = document.querySelector('.ytp-next-button'); if (!b) return false; b.click(); return true; })()
        """
    private static let previousJS = """
        (() => { const b = document.querySelector('.ytp-prev-button'); if (!b) return false; b.click(); return true; })()
        """
    private static let volumeGetJS = """
        (() => { \(BrowserJS.pick) const p = bhPick(); return p ? Math.round(p.el.volume * 100) : null; })()
        """
    // Volume *is* meaningful on a call, so this one does not decline a live pick.
    // It writes the whole group: a meeting's audio lives in one element per
    // participant, and setting just one would leave the rest at full volume.
    private static let volumeSetJS = """
        (() => { \(BrowserJS.pick) const p = bhPick(); if (!p) return false; const v = Math.max(0, Math.min(1, {volume} / 100)); p.group.forEach(x => { x.volume = v; }); return true; })()
        """
    private static let playStateJS = """
        (() => { \(BrowserJS.pick) const p = bhPick(); if (!p || p.live) return null; return p.el.paused ? 'paused' : 'playing'; })()
        """

    private static func browserDefinition(
        id: String,
        displayName: String,
        bundleID: String,
        script: (String) -> String
    ) -> AppDefinition {
        AppDefinition(
            id: id, displayName: displayName, bundleID: bundleID, isBuiltIn: true,
            playPauseScript: script(playPauseJS),
            nextScript: script(nextJS),
            previousScript: script(previousJS),
            volumeScaleKind: .integer(max: 100),
            volumeGetScript: script(volumeGetJS),
            volumeSetScript: script(volumeSetJS),
            playStateScript: script(playStateJS))
    }

    private static func safariScript(javascript: String) -> String {
        """
        tell application "Safari"
            if not (exists front window) then return
            set targetTab to missing value
            repeat with browserWindow in windows
                repeat with candidateTab in tabs of browserWindow
                    try
                        if (do JavaScript "sessionStorage.getItem('beamhook-selected') === '1'" in candidateTab) is true then set targetTab to candidateTab
                    end try
                end repeat
            end repeat
            if targetTab is missing value then set targetTab to current tab of front window
            return do JavaScript "\(javascript)" in targetTab
        end tell
        """
    }

    private static func chromiumScript(application: String, javascript: String) -> String {
        """
        tell application "\(application)"
            if not (exists front window) then return
            set targetTab to missing value
            repeat with browserWindow in windows
                repeat with candidateTab in tabs of browserWindow
                    try
                        if (execute candidateTab javascript "sessionStorage.getItem('beamhook-selected') === '1'") is true then set targetTab to candidateTab
                    end try
                end repeat
            end repeat
            if targetTab is missing value then set targetTab to active tab of front window
            return execute targetTab javascript "\(javascript)"
        end tell
        """
    }
}
