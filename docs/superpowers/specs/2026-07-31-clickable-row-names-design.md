# Click a row's name to bring that app or tab forward — Design

**Date:** 2026-07-31
**Status:** Approved for planning

## Problem

The popover lists the apps that are playing or open — Spotify, Safari, Brave,
Chrome — and, under a browser, each of its media tabs by title. Every row is a
thing the user is looking at and can act on: hook it, pause it, change its
volume. The one obvious action missing is the plainest one: *go there*. Seeing
"Digital painting…" listed under Safari and wanting to look at it currently
means dismissing the popover and hunting for the tab by hand.

Wanted: clicking a row's name brings that app to the front, and clicking a
browser tab's name brings that exact tab to the front.

## Behavior

- **Two labels become clickable.** `AppVolumeRow`'s app name and
  `BrowserVolumeRow`'s tab title. The hooked app's row at the top is included —
  there is no reason its name should behave differently from the rows below it.
- **The target picker at the top of the popover is untouched.** That `Text` is a
  `Menu` label; its click already opens the dropdown.
- **App name → activate that app.** Every row's app is running by construction:
  `PlayingAppsListAvailable.rows` is built from Core Audio's playing list plus
  volume-scriptable apps filtered through `AppState.isRunning`. So there is no
  launch path, no not-installed case, and no progress state to show. An app that
  quit between the last refresh and the click is a silent no-op; the row
  disappears at the next 3-second refresh.
- **Tab name → focus that tab, then activate the browser.** The tab is made its
  window's current tab and that window is raised, so activating the browser lands
  the user on the tab they clicked.
- **A browser's own name only activates it.** Clicking "Safari" brings Safari
  forward on whatever tab it was already showing. Choosing a tab for the user
  belongs to the tab rows underneath, which name the tabs explicitly.
- **A tab that is gone falls back to activating the browser.** The user asked to
  go to Safari's YouTube tab; if that tab has since closed, arriving in Safari is
  a better answer than nothing happening.
- **Nothing dismisses the popover explicitly.** Activating another app
  deactivates Beamhook, and a `.transient` popover closes itself.
- **Affordance is the cursor only.** The name looks exactly as it does today; the
  cursor becomes a pointing hand over it. The rows already carry sliders and two
  kinds of button, and a hover underline or highlight would add a third visual
  state to a popover whose calm is worth keeping.

## Why not reuse `select` or `TargetLauncher`

Two existing pieces look close enough to reuse and are not:

- `BrowserMediaController.select` walks every window and tab evaluating the
  identity JS, but its purpose is to *mark* a tab in `sessionStorage` for the
  static command scripts. It deliberately never touches window or tab ordering.
  Focus needs the AppleScript position of the matching tab, which `select`
  discards.
- `TargetLauncher` / `WorkspaceAppLauncher` exist to start a quit app *without*
  stealing focus — `configuration.activates = false` is the entire point, since a
  media key must never pull the user out of what they are doing. This feature is
  the exact opposite: a deliberate click that should raise a running app. Sharing
  code would mean a flag that inverts the one behavior the launcher is named for.

## Architecture

### `Sources/Beamhook/System/AppleScriptExecutor.swift`

A `focus(_:)` method on `BrowserMediaController`, alongside `select`, plus its
`focusScript(_:)` generator.

The script follows `selectionScript`'s shape — walk windows and tabs, evaluate
JS that compares the page-owned `__beamhookSourceID_v1` against the candidate's
`sourceID`, act on `MATCH` — with one structural change: the inner loop must be
index-based (`repeat with tabIndex from 1 to count of tabs of browserWindow`)
because the Chromium browsers address the active tab by index. Safari sets
`current tab of browserWindow to tab tabIndex of browserWindow`; Chrome, Brave,
Arc and Vivaldi set `active tab index of browserWindow to tabIndex`. Both then
raise the window with `set index of browserWindow to 1`.

Identity is validated in the page exactly as every other action does, so a
reordered or replaced tab cannot cause the wrong tab to be focused. As with the
siblings, a miss ends in `error "…"` so the caller sees `succeeded == false`.

The app is *not* activated from inside the `tell` block. AppleScript `activate`
on a running app is safe, but keeping activation in Swift keeps the script to one
job and lets the fallback (tab gone → activate anyway) live in one place.

### `Sources/Beamhook/AppState.swift`

```swift
func activate(bundleID: String)                       // main actor, NSRunningApplication
func focusBrowserSource(_ candidate: BrowserMediaCandidate) async
```

`activate` mirrors the inline style of the existing `isRunning(bundleID:)`:
look the app up in `NSRunningApplication.runningApplications(withBundleIdentifier:)`
and call `activate()`. No new seam — it is one system call with no logic.

`focusBrowserSource` runs `focus(_:)` on the `ScriptRunner` queue, the same lane
and off-main discipline as `performBrowserCommand`, then hops back to the main
actor and activates the browser's bundle id whether or not the script succeeded.

### `Sources/Beamhook/UI/PointingHandCursor.swift` (new)

A small `NSViewRepresentable` whose view overrides `resetCursorRects` to set
`NSCursor.pointingHand` over its bounds, applied as an `.overlay` on the two
labels.

Deliberately not `.onHover { NSCursor.pointingHand.push() … pop() }`: these rows
are rebuilt on a 3-second refresh, and a row that disappears while hovered never
runs its exit branch, stranding a pointing-hand cursor over the whole popover.
Cursor rects are owned by the window and rebuilt with the view hierarchy, so they
cannot leak that way.

### `Sources/Beamhook/UI/MenuContentView.swift`

Both labels gain the same treatment: `.contentShape(Rectangle())` so the whole
label area is hittable, `.onTapGesture` calling the matching `AppState` method,
the cursor overlay, `.accessibilityAddTraits(.isButton)`, and a `.help` tooltip
naming the action ("Show Spotify"). `BrowserVolumeRow`'s label already has a
`.help` carrying the full title, which is what makes a truncated one readable —
that tooltip gains the action rather than losing the title
("Switch to this tab: Digital painting…").

## Testing

`Tests/BeamhookTests/BrowserMediaControllerTests.swift` already has both patterns
this needs — `RecordingScriptExecutor` for asserting generated script contents,
and `testTargetedSafariActionAppleScriptCompiles` for compiling generated source
through `NSAppleScript`. Three additions:

- the focus script carries the candidate's exact `sourceID`, so focus cannot be
  aimed by cached position alone;
- the Safari focus script compiles;
- a Chromium focus script compiles (they take the other branch).

`AppState.activate` is a single `NSRunningApplication` call and gets no test;
`focusBrowserSource`'s value is in the script and the queue discipline, both
covered above.

## Out of scope

- Making the whole row clickable. The rows hold sliders and buttons; widening the
  hit target invites mis-clicks that move focus away from the popover.
- Focusing a tab in a browser that is not running. Rows only exist for running
  browsers.
- Any change to the target picker or the hook/unhook buttons.
