# Per-source menu-bar icons

Date: 2026-07-28

## Problem

The menu-bar glyph is always the same hook, so nothing on screen says *which*
app the media keys are currently hooked to. Answering that question costs a
click into the popover.

## Behaviour

The status item shows a badged hook for the sources we ship art for, and the
plain hook for everything else.

| Hooked target | Glyph |
| --- | --- |
| Spotify (`spotify`) | hook + Spotify |
| Apple Music (`music`) | hook + music note |
| Safari (`safari-youtube`) | hook + compass |
| Chrome (`chrome-youtube`) | hook + Chrome |
| any browser target whose hooked tab is on YouTube | hook + YouTube |
| everything else | plain hook |

"Everything else" is VLC, VOX, Apple TV, QuickTime, Downcast, Brave, Arc,
Vivaldi, user-added apps, and no target at all.

The YouTube badge takes priority over the browser badge: a YouTube tab in Safari
shows YouTube, not the compass.

### Deliberate omissions

- **Brave, Arc and Vivaldi keep the plain hook.** They are separate browsers with
  their own marks; showing Chrome's badge because they happen to be Chromium
  would be wrong. They still get the YouTube badge when the hooked tab is
  YouTube, since that rule is host-driven and browser-agnostic.
- **`Icon/menubar-podcasts.png` stays unwired.** Apple Podcasts has no
  AppleScript dictionary (`sdef /System/Applications/Podcasts.app` fails with
  error -192), so it cannot be a Beamhook target. Downcast is the only podcast
  built-in and is not what the art depicts. The file stays on disk for whenever a
  target fits it.
- **Placement is the menu-bar status item only.** Not the target picker, the
  popover footer, the hook HUD, or the playing-apps rows.

## Art

The six PNGs in `Icon/` are 128x128, pure black with transparent cutouts, with
the badge drawn at roughly 70% alpha so it reads as a secondary mark. That
matters because the menu-bar image is a template: macOS discards colour and
fills every non-transparent pixel with the menu-bar tint, so any badge relying on
greyscale would collapse into a featureless black square.

Measured ink geometry, as a fraction of frame width:

| File | hook x-start | hook height |
| --- | --- | --- |
| current plain `menubar.png` | 25.0% | 86.1% |
| all six badged files | 29.7% | 82.0% |

The badged files agree with each other exactly. Against the plain hook they
differ by under a pixel at 18pt, which is below the threshold worth new art for.
Exporting a plain hook on the badged grid as `Icon/menubar-plain.png` would take
the drift to zero; the icon script picks that file up automatically if it ever
appears.

## Components

### `BeamhookKit/MenuBarGlyph.swift` (new)

An enum whose raw values are asset-catalog names, plus one resolver:

```swift
public static func forTarget(id: String?, browserHost: String? = nil) -> MenuBarGlyph
```

Pure logic, no AppKit — the app target only renders what this returns. Host
matching is anchored (`youtube.com`, any `*.youtube.com` so YouTube Music counts,
or `youtu.be`), case-insensitive, and tolerates a leading `www.`. An anchored
match is what keeps `notyoutube.com` from scoring.

`browserHost` is supplied only for browser targets; callers pass `nil` otherwise.

### Browser scan gains a hostname

`AppleScriptExecutor.swift`'s scan JS adds `host: location.hostname` to its JSON
payload. `Payload.host` decodes as optional so older fixtures stay valid;
`BrowserMediaCandidate` carries it as a non-optional `String`, defaulting to
empty.

### `AppState`

Publishes `menuBarGlyph`, recomputed from the `didSet` of the three inputs that
can change it: `selectedTargetID`, `selectedBrowserMediaID`, and
`browserMediaCandidates`. The host comes from the hooked candidate, and only when
the target is a browser.

### `AppDelegate`

Subscribes to `$menuBarGlyph` with Combine, `removeDuplicates()`, and swaps
`statusItem.button.image`. `@Published` fires on subscribe, so this replaces the
current one-shot image assignment rather than duplicating it. A missing asset
falls back to the plain hook instead of leaving the status item blank.

### `Icon/make-icons.sh`

Gains a loop generating `MenuBarIcon-<Name>.imageset` at 18px/36px from each
`Icon/menubar-<slug>.png`.

It also stops overwriting the plain hook from `Icon/menubar-master.png`. That
master was edited on Jul 2, after the assets were last generated, and now carries
an opaque off-white background — running the script as it stands would replace
the menu-bar hook with a solid black rounded rectangle. The step now reads
`Icon/menubar-plain.png` and, when that file is absent, warns and leaves the
committed asset untouched.

## Known limitation

Browser tab scans run at startup, while the popover is open, and on manual tab
selection — never on a timer in the background. So the YouTube badge can go
stale: hooked to Chrome, switching from a YouTube tab to something else leaves
the badge on YouTube until the popover is next opened.

Keeping it live would mean firing Apple events on a background timer forever,
which costs battery and needs automation permission held open, for a glanceable
icon. Accepted as-is.

## Testing

**`BeamhookKitTests/MenuBarGlyphTests.swift`** — the mapping table, `nil` and
unknown ids falling back to the plain hook, and YouTube host variants
(`youtube.com`, `www.`, `m.`, `music.`, `youtu.be`, mixed case) plus the
`notyoutube.com` trap that a naive `contains` would fail.

**`BeamhookTests/MenuBarGlyphAssetTests.swift`** — every `MenuBarGlyph` case
resolves to a real bundled image, so a typo'd or missing imageset fails the build
rather than shipping a blank menu bar.

**`BeamhookTests/BrowserMediaControllerTests.swift`** — scan fixtures updated for
the new `host` field, with an assertion that it parses.
