# Launch the hooked app on play/pause — Design

**Date:** 2026-07-30
**Status:** Approved for planning

## Problem

When the hooked target is not running, pressing play/pause does nothing at all —
and it does nothing in the worst possible way. `MediaKeyTap` keeps
`transportKeysHijacked == true` for every non-browser target regardless of
whether that app is running (`AppState.configureBrowserTransportForPendingScan`),
so the key is swallowed. `TargetManager.route` then drops it, because
`app.isReady` is false. The press is consumed and nothing happens: macOS does not
get its fallback either.

The same guard drops a press aimed at an app that is *mid-launch* — running but
not yet `isFinishedLaunching`.

Wanted: with Spotify hooked but quit, pressing play/pause starts Spotify and
begins playback.

## Behavior

- **Play/pause only.** Next/previous on a quit app have no meaningful target —
  there is no queue to skip within — so they keep today's behavior.
- **A user setting, default ON.** Lives in the new Settings window (below). The
  key is already dedicated to that app and currently does nothing, so launching
  is the better default; users who don't want a quit app relaunching can turn it
  off.
- **Browser targets are excluded.** When a browser target isn't running,
  `refreshBrowserMedia` sets `transportKeysHijacked = false` and macOS handles
  the key — Beamhook never sees the press. Claiming it in order to launch Safari
  would produce a freshly launched browser with no media tab to play, which is
  worse than the current pass-through.
- **The popover's play/pause button** follows the same rule: it is equally dead
  on a quit target today and goes through the same coordinator.

## Why not let AppleScript launch the app

`tell application "Spotify" to playpause` launches Spotify implicitly, so the
whole feature could be "drop the `isReady` guard". Rejected:

- The Apple-event send blocks until the target finishes launching. That is the
  ~2-minute stall behind the July 2026 freeze, and it would sit on the serial
  `ScriptRunner` command lane with every later key press queued behind it.
- It cannot work for menu-driven targets (IINA and the Electron players), which
  have no scripting dictionary — there is nothing to address an Apple event to.

Instead: launch explicitly and asynchronously, poll for readiness, then play
through the existing command lane. Nothing blocks the tap, the UI, or the lane.

## Architecture

### `Sources/BeamhookKit/TargetLauncher.swift` (new)

Two protocol seams plus the coordinator, following the kit's existing pattern of
pure logic behind injected system access.

```swift
public protocol AppLaunching {
    /// Asks the system to launch this app. False when it isn't installed.
    func launch(bundleID: String) async -> Bool
}

/// Test seam so the readiness poll runs instantly under test.
public protocol Sleeping {
    func sleep(seconds: Double) async
}

public enum TargetLaunchOutcome: Equatable {
    case skipped         // a launch was already in flight, or the target changed
    case notInstalled
    case timedOut
    case alreadyPlaying  // the app resumed on its own; nothing sent
    case played
}
```

`TargetLauncher` is `@MainActor` (its single-flight flag is then race-free, and
its caller `AppState` is already main-actor isolated). It is constructed with the
`AppLaunching`, a `Sleeping`, and the **command-lane** `ScriptRunning` — the same
runner user key presses use, so the play it sends is serialized against them.

```swift
func launchAndPlay(_ app: MediaApp,
                   isStillHooked: @escaping () -> Bool,
                   onLaunchStarted: @escaping () -> Void) async -> TargetLaunchOutcome
```

`onLaunchStarted` fires exactly once, after the single-flight and installed
checks pass and immediately before the readiness wait. It is what drives the HUD
(below), keeping "is anything actually starting?" inside the coordinator where
the tests can pin it, rather than re-derived by the caller.

Steps:

1. Return `.skipped` if a launch is already in flight. Set the flag (cleared in a
   `defer`).
2. If `!app.isRunning`, call `launcher.launch(bundleID:)`. False → `.notInstalled`.
   Already running (mid-launch) → skip straight to the wait, which is what closes
   the dropped-press-while-launching gap.
3. Poll `app.isReady` every **250 ms**, up to **15 s**, sleeping through the
   injected `Sleeping`. Still not ready → `.timedOut`, quietly; the next press
   retries.
4. Check `isStillHooked()`. False → `.skipped`: the user changed target while the
   launch was in flight, and playing the old one would be wrong. This mirrors the
   `PlaybackTargetContext` discipline already used for async playback reads.
5. On the command runner, off-main: read `app.isPlaying()`. `true` → return
   `.alreadyPlaying` and send nothing. Otherwise `app.perform(.playPause)` and
   return `.played`.

Step 5's read is load-bearing: an app that auto-resumes on launch would be
*paused* by an unconditional playPause. `nil` (unknown state, e.g. a definition
with no `playStateScript`) is treated as not playing — a freshly launched app is
overwhelmingly likely to be paused.

### `Sources/Beamhook/System/WorkspaceAppLauncher.swift` (new)

The `AppLaunching` implementation. `NSWorkspace.shared.urlForApplication(
withBundleIdentifier:)` → nil means not installed, return false. Otherwise
`openApplication(at:configuration:)` with:

- `configuration.activates = false` — pressing play must not yank focus out of
  whatever the user is doing.
- `configuration.addsToRecentItems = false`.

A `TaskSleeper` (`Task.sleep`) implements `Sleeping` alongside it.

### `Sources/Beamhook/AppState.swift` (wiring)

- New `@Published var launchTargetOnPlay: Bool`, read at init from the UserDefaults
  key `"launchTargetOnPlay"` and defaulting to `true` when the key is absent, with
  a `setLaunchTargetOnPlay(_:)` that persists it — the same shape as
  `loginItemEnabled` / `setLoginItem`, which is what the General tab binds to.
- `handleKey`'s transport branch, after the existing `targetManager.route(key)`:
  when the route returned **false** (nothing happened), the key was
  `.playPause`, `launchTargetOnPlay` is on, the target is **not** a browser, and
  the target resolves in the registry → call `launcher.launchAndPlay`, capturing
  the target id for `isStillHooked`.
- `togglePlayPauseTarget` gains the same fallback for its non-browser branch.

`route` returning false already means exactly "no command was delivered" (no
target, or not ready), so it is a sound trigger.

## Settings window

Three controls now live in the popover via `SettingsSection`, and the popover is
only 220pt wide. They move to a real window; the new toggle joins them.

- **`Sources/Beamhook/UI/SettingsWindow.swift`** (new) — mirrors `AddAppWindow`:
  posts `.closeBeamhookMenu`, hosts an `NSWindow` (`[.titled, .closable]`,
  centered, `isReleasedWhenClosed = false`), reuses the window on reopen. A real
  window, never a `.sheet` — a sheet would dismiss the menu-bar popover.
- **`Sources/Beamhook/UI/SettingsView.swift`** (new) — a `TabView` with two tabs:
  - **General:** "Launch at login"; "Launch the hooked app on play/pause" with
    the caption "Starts the app if it isn't running."
  - **Apps:** the "Add an app…" button and the custom-app list with its remove
    buttons, moved verbatim from `SettingsSection`.
- **`Sources/Beamhook/UI/SettingsSection.swift`** is deleted; `MenuContentView`
  drops it (and its `Divider`) and gains a gear button in the footer row beside
  Quit. The popover gets shorter.

### Activation-policy ref-counting

`AddAppWindow` sets `NSApp.setActivationPolicy(.regular)` on show and `.accessory`
on `willClose`. With two windows that is a bug: opening Add an app… from the
Settings window and then closing it drops the app to `.accessory` while the
Settings window is still open.

New `Sources/Beamhook/UI/AgentWindowPresenter.swift`: a `@MainActor` helper that
counts registered open windows, sets `.regular` on the first and `.accessory`
only when the last one closes. `AddAppWindow` and `SettingsWindow` both use it,
which removes the policy flipping from `AddAppWindow` itself.

## Feedback

A cold start takes seconds; silence reads as a broken key press. `HookHUD.Presentation`
gains a `case launching(appName: String)` with a 2.0 s `hideDelay`, showing
"Starting <app>…". `AppState` presents it from the `onLaunchStarted` callback, so
it never flashes for a press that was skipped or for an app that isn't installed.
Panel layout is unchanged — it is the same single-line form as `.hooked`.

## Edge cases

| Case | Behavior |
|---|---|
| App not installed | No-op, logged. No HUD (nothing is starting). |
| Launch exceeds 15 s | Give up silently; the next press retries. |
| App auto-resumes on launch | `isPlaying()` read prevents an unwanted pause. |
| Second press while launching | Ignored (`.skipped`) — no launch-then-pause. |
| Target changed mid-launch | `.skipped`; the newly launched app is left alone. |
| Menu-driven target (IINA) | Works — the play menu item is pressed once the menu bar exists. An app launched with an empty queue (TIDAL) plays nothing; unavoidable, worth a README line. |
| Automation permission | Unchanged. The first script to a newly launched app may raise the usual macOS prompt. |

No new entitlement or permission: launching another app needs neither.

## Testing

**Kit unit tests** (`Tests/BeamhookKitTests/TargetLauncherTests.swift`) with a
fake launcher, a fake presence checker that flips to ready after N polls, an
immediate `Sleeping`, and the existing `Mocks.swift` fakes:

- launches once and performs `.playPause` when the app was not running;
- does **not** call `launch` when the app is already running, but still waits and
  plays;
- `.notInstalled` when the launcher returns false — no play sent;
- `.timedOut` when readiness never arrives — no play sent, and the poll is
  bounded (assert the sleep count);
- `.alreadyPlaying` sends nothing when `isPlaying()` is true;
- `nil` play state still plays;
- a second concurrent call returns `.skipped` and launches nothing;
- `.skipped` when `isStillHooked()` goes false during the wait;
- `onLaunchStarted` fires exactly once on a real launch, and not at all for
  `.skipped` or `.notInstalled`.

**Manual** (`./run.sh`):

- Quit Spotify → press play → Spotify launches, focus stays put, playback starts.
- Press play twice during the launch → one launch, still playing (not paused).
- Toggle the setting off → press play on a quit target → nothing happens.
- Hook Safari, quit it → macOS still handles play/pause (unchanged).
- Open Settings, open Add an app… from it, close Add an app… → the Settings
  window stays usable and key.

`xcodegen generate` after adding/removing files (three added, one deleted).

## Out of scope

- Launching on next/previous.
- Launching a browser target, and any attempt to restore a media tab in one.
- An Updates tab in the Settings window.
