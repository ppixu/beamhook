import Foundation

/// JavaScript shared by every browser-facing script: the built-in browser
/// `AppDefinition`s here and `BrowserMediaController` in the app target both
/// prepend `BrowserJS.pick`, so a scan and the command that follows it can never
/// disagree about which element on a page is "the" media source.
///
/// The snippet is interpolated into an AppleScript double-quoted string literal,
/// so it must contain **single quotes only** and no backslashes.
public enum BrowserJS {
    /// Defines `bhLive(el)` and `bhPick()`.
    ///
    /// `bhPick()` returns `{el, live, group}`, or `null` when the page holds no
    /// media element at all:
    ///
    /// - `el` — the element transport and play-state act on.
    /// - `live` — the page's media is a call/conference stream (Meet, Teams,
    ///   Discord, Jitsi …). Those have no meaningful transport: pausing a live
    ///   `MediaStream` only freezes the user's own view of the call.
    /// - `group` — the elements a volume write applies to. For a call that is
    ///   *every* live element, because the audio is spread across one element
    ///   per participant.
    ///
    /// A *playing* regular element always wins, so a call tab that also holds an
    /// incidental paused `<audio>` still reads as a call. `instanceof
    /// MediaStream` rather than a truthiness test on `srcObject`, because Chrome
    /// also accepts `srcObject = MediaSource` for ordinary MSE playback.
    public static let pick = """
    const bhLive = el => typeof MediaStream !== 'undefined' && el.srcObject instanceof MediaStream; const bhPick = () => { const all = Array.from(document.querySelectorAll('video,audio')); const live = all.filter(bhLive); const regular = all.filter(el => !bhLive(el)); const playing = regular.filter(x => !x.paused && !x.ended); if (playing.length) return {el: playing[0], live: false, group: playing}; if (live.length) { const active = live.filter(x => !x.paused && !x.ended); return {el: active[0] || live[0], live: true, group: live}; } return regular[0] ? {el: regular[0], live: false, group: [regular[0]]} : null; };
    """
}
