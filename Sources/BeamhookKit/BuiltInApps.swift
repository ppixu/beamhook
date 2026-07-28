import Foundation

public enum BuiltInApps {
    public static let all: [AppDefinition] = [
        spotify, music, appleTV, safariYouTube, chromeYouTube, braveYouTube,
        arcYouTube, vivaldiYouTube, vlc, vox, quickTime, downcast,
        iina, amazonMusic, tidal, plexamp, deezer,
    ]

    // MARK: - Menu-driven targets
    //
    // Apps with no AppleScript dictionary at all, driven by pressing their own menu
    // items over the Accessibility API. Menu indices are 0-based and the Apple menu
    // is index 0, so an app's first own menu is 1. Titles are matched before
    // indices; see `MenuItemPath` for why both are carried.

    /// IINA has no scripting dictionary — the AppleScript request has been open
    /// upstream since 2017 (iina/iina#316) — but its Playback menu gives us
    /// everything the transport keys need.
    ///
    /// Verified against IINA 1.4.4 on macOS 26.5: pressing the item toggles
    /// playback, and its title tracks state ("Pause" while playing, "Resume" while
    /// paused, per MenuController). The title can lag right after a press, so treat
    /// a single stale read as normal rather than as a failed press.
    ///
    /// Menu positions observed live: Playback is menu 4, play/pause item 0, with
    /// Next Media at 27 and Previous Media at 28 — but titles resolve it first, so
    /// the indices only matter for a localized IINA.
    public static let iina = AppDefinition.menuDriven(
        id: "iina", displayName: "IINA", bundleID: "com.colliderli.iina",
        control: MenuControl(
            playPause: MenuItemPath(menuIndex: 4, menuTitles: ["Playback"],
                                    itemIndex: 0, itemTitles: ["Pause", "Resume"]),
            next: MenuItemPath(menuIndex: 4, menuTitles: ["Playback"],
                               itemIndex: 27, itemTitles: ["Next Media"]),
            previous: MenuItemPath(menuIndex: 4, menuTitles: ["Playback"],
                                   itemIndex: 28, itemTitles: ["Previous Media"]),
            playingTitles: ["Pause"], pausedTitles: ["Resume"]))

    /// Amazon Music. Indices come from BeardedSpice's shipping adapter, which drives
    /// this exact menu: menu 4, play/pause at 0, next at 1, previous at 2. Its
    /// author notes the app is English-only, so the titles are safe to match on.
    /// Not exercised against a running copy here.
    public static let amazonMusic = AppDefinition.menuDriven(
        id: "amazon-music", displayName: "Amazon Music", bundleID: "com.amazon.music",
        control: MenuControl(
            playPause: MenuItemPath(menuIndex: 4, menuTitles: [],
                                    itemIndex: 0, itemTitles: ["Pause", "Play"]),
            next: MenuItemPath(menuIndex: 4, menuTitles: [], itemIndex: 1, itemTitles: ["Next"]),
            previous: MenuItemPath(menuIndex: 4, menuTitles: [], itemIndex: 2, itemTitles: ["Previous"]),
            playingTitles: ["Pause"], pausedTitles: ["Play"]))

    /// TIDAL. Menu layout confirmed live on this Mac: Playback is menu 4, with
    /// Play at 0, Previous at 2 and Next at 3 — matching BeardedSpice's older
    /// indices exactly. What is NOT confirmed is the press firing: the test ran
    /// with no track queued, and Play with an empty queue does nothing either way.
    /// (TIDAL also exposes Volume up/down items, if per-app volume is ever wanted.)
    public static let tidal = AppDefinition.menuDriven(
        id: "tidal", displayName: "TIDAL", bundleID: "com.tidal.desktop",
        control: MenuControl(
            playPause: MenuItemPath(menuIndex: 4, menuTitles: [],
                                    itemIndex: 0, itemTitles: ["Pause", "Play"]),
            next: MenuItemPath(menuIndex: 4, menuTitles: [], itemIndex: 3, itemTitles: ["Next"]),
            previous: MenuItemPath(menuIndex: 4, menuTitles: [], itemIndex: 2, itemTitles: ["Previous"]),
            playingTitles: ["Pause"], pausedTitles: ["Play"]))

    /// Plexamp. Nobody has mapped its menu bar, so this searches for the titles
    /// instead of claiming positions: it works if those items exist and does
    /// nothing if they do not. Replace with indices once someone runs the menu
    /// probe against it (see CLAUDE.md).
    public static let plexamp = AppDefinition.menuDriven(
        id: "plexamp", displayName: "Plexamp", bundleID: "tv.plex.plexamp",
        control: MenuControl(
            playPause: .search(itemTitles: ["Play/Pause", "Pause", "Play", "Resume"]),
            next: .search(itemTitles: ["Next", "Next Track", "Play Next"]),
            previous: .search(itemTitles: ["Previous", "Previous Track", "Play Previous"]),
            playingTitles: ["Pause"], pausedTitles: ["Play", "Resume"]))

    /// Deezer. Unmapped like Plexamp, and the weaker bet of the two: its public
    /// playback controls live in Deezer's own status-bar popup, and there is no
    /// evidence its app menu carries transport items at all. Bundle id from the
    /// Homebrew cask's zap stanza, as for Plexamp.
    public static let deezer = AppDefinition.menuDriven(
        id: "deezer", displayName: "Deezer", bundleID: "com.deezer.deezer-desktop",
        control: MenuControl(
            playPause: .search(itemTitles: ["Play/Pause", "Pause", "Play", "Resume"]),
            next: .search(itemTitles: ["Next", "Next Track", "Next Song"]),
            previous: .search(itemTitles: ["Previous", "Previous Track", "Previous Song"]),
            playingTitles: ["Pause"], pausedTitles: ["Play", "Resume"]))

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
