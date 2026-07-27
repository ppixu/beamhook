# Browser call tabs are not transport sources — Design

**Date:** 2026-07-27
**Status:** Approved for planning

## Problem

`BrowserMediaController.scan` surfaces any tab that owns a `<video>`/`<audio>`
element or `navigator.mediaSession` metadata. A Google Meet tab qualifies: its
participant tiles are real `<video>` elements. So Meet appears in Beamhook's
source list with a play/pause button and can be auto-selected as the hooked tab.

Neither is useful, and one is harmful:

- Pressing pause calls `.pause()` on a live `MediaStream`. The user's view of the
  call freezes until something calls `.play()` again.
- Auto-selection at `AppState.refreshBrowserMedia` picks
  `first(isSelected) ?? first(isPlaying) ?? first`. A call reports
  `playing: true` for its whole duration, so an all-day meeting can silently
  claim the media keys away from a real player.

Volume, by contrast, *is* meaningful on a call tab and stays available.

## Detection

One predicate, no hostname list. Meet, Teams, Discord, Jitsi and Whereby all
render remote participants through a `MediaStream`; a site list would need
permanent maintenance and would still miss things.

```js
const bhLive = el => typeof MediaStream !== 'undefined' && el.srcObject instanceof MediaStream;
```

`instanceof MediaStream` rather than a truthiness test on `srcObject`, because
Chrome also accepts `srcObject = MediaSource` for ordinary MSE playback, which
must keep working normally.

### Element selection order

Selection is explicitly ordered so that a call tab holding an incidental paused
`<audio>` still reads as a call:

1. A **playing non-live** element → regular source.
2. Otherwise, **any live element present** → call source (prefer a playing live
   element, else the first live one).
3. Otherwise, the **first non-live** element → regular source (a paused YouTube
   tab lands here).

### Shared snippet

The idiom `all.find(x => !x.paused && !x.ended) || all[0]` is currently
duplicated in eight scripts across `Sources/BeamhookKit/BuiltInApps.swift` and
`Sources/Beamhook/System/AppleScriptExecutor.swift`. The rule above replaces all
eight, and scan and commands must never disagree about which element they mean,
so it becomes one shared constant.

New file `Sources/BeamhookKit/BrowserJS.swift` holding one `public static let`
prelude:

```js
const bhLive = el => typeof MediaStream !== 'undefined' && el.srcObject instanceof MediaStream;
const bhPick = () => {
  const all = Array.from(document.querySelectorAll('video,audio'));
  const live = all.filter(bhLive);
  const regular = all.filter(el => !bhLive(el));
  const playing = regular.filter(x => !x.paused && !x.ended);
  if (playing.length) return {el: playing[0], live: false, group: playing};
  if (live.length) {
    const active = live.filter(x => !x.paused && !x.ended);
    return {el: active[0] || live[0], live: true, group: live};
  }
  return regular[0] ? {el: regular[0], live: false, group: [regular[0]]} : null;
};
```

(Minified onto one line in the source, matching the existing snippets.)

`bhPick()` returns `null` when the page has no media element at all. `el` is the
element transport and play-state act on; `group` is the set a volume write
applies to — the currently playing elements for a regular source, and *every*
live element for a call, because a call's audio is spread across one element per
participant. Every browser script is built as `BrowserJS.prelude + <body>`.

**Constraint:** the snippet is interpolated into an AppleScript double-quoted
string literal, so it must contain **single quotes only** — the same rule the
existing snippets already follow.

## Behaviour per surface

| Surface | Behaviour for a call source |
|---|---|
| `BrowserMediaCandidate` | new `supportsTransport: Bool` |
| Scan payload | new `live: Bool` field; `supportsTransport = !live` |
| `BrowserVolumeRow` (`MenuContentView.swift`) | play/pause button omitted; title and volume slider unchanged |
| Hook picker (`MenuContentView.swift:72`) | call tabs stay listed and hookable — hooking one routes volume keys to it |
| Auto-selection (`AppState.refreshBrowserMedia`) | never auto-picks a call over a transport-capable tab (order below) |
| Main play/pause button (`MenuContentView.swift:64`) | disabled while the hooked source is a call |
| `BuiltInApps.playPauseJS` | returns `false` on a live pick — the backstop, so even a stale selection cannot freeze a call |
| `BuiltInApps.nextJS` / `previousJS` | unchanged; they only click `.ytp-next-button` / `.ytp-prev-button`, which no call page has |
| `BuiltInApps.playStateJS` | returns `null` on a live pick, so the poll reports "unknown" rather than a bogus "playing" |
| Volume get/set (both files) | reads `bhPick().el`, writes `bhPick().group` — so a call's volume is set across all participant elements, and a regular source behaves as it does today |

### New auto-selection order

```
first(isSelected)                        // explicit user choice always wins
?? first(isPlaying && supportsTransport)
?? first(supportsTransport)
?? first(isPlaying)
?? first
```

`first(isSelected)` stays unconditional: if the user deliberately hooked a call
tab to get volume-key control, Beamhook must not override that on the next scan.

### Supporting state

`AppState` exposes whether the currently hooked browser source supports
transport, derived from `selectedBrowserMediaID` against
`browserMediaCandidates`, so `MenuContentView` can disable the main play/pause
button.

## Decisions

- **Media keys stay swallowed** when a call tab is hooked. Play/pause becomes a
  genuine no-op. Letting the key fall through to macOS would hand it to the
  browser's own media session, which pauses the call — exactly the outcome being
  fixed. `tap.transportKeysHijacked` therefore keeps its current meaning and is
  not made source-dependent.
- **Call tabs remain hookable**, per user decision: volume-key control over a
  meeting is wanted; transport control is not.
- `Payload.live` decodes as non-optional `Bool`. The injected script and the
  decoder ship in the same binary and a fresh script is injected on every scan,
  so the field is always present.

## Non-goals

- No hostname or site list.
- No detection of screen sharing, microphone capture, or WebAudio-only apps
  (the Zoom web client renders through canvas + WebAudio and exposes no media
  element, so it never appears as a source in the first place).
- No new UI affordance explaining why a call has no play button; its absence is
  the explanation.

## Testing

Unit tests (`Tests/BeamhookTests/BrowserMediaControllerTests.swift`) — the
`scanOutput` helper gains a `live` parameter defaulting to `false`:

- `live: false` payload → `supportsTransport == true`.
- `live: true` payload → `supportsTransport == false`.
- A scan mixing both rows → each candidate carries its own flag, and both remain
  in the list (a call is filtered from *transport*, never from the list).

The injected JavaScript itself cannot be unit-tested — the repo has no JS
harness — so element-selection ordering is verified manually.

Manual verification via `./run.sh`, with a Meet call and a playing YouTube tab
open in the same browser:

1. The Meet row shows its volume slider and **no** play/pause button.
2. The YouTube row keeps both.
3. With the browser hooked and neither tab explicitly selected, the media key
   reaches YouTube, not Meet.
4. Hooking the Meet tab explicitly: volume keys change call volume, the main
   play/pause button is disabled, and the play/pause key does nothing — the call
   keeps running.
