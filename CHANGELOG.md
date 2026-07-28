# Changelog

Notable changes to Beamhook. The signed & notarized official build for each
release is available on [Gumroad](https://ppixu.gumroad.com/l/beamhook) (€5,
one-time, includes all 1.x updates); building from source is always free.

## [1.1.6] — 2026-07-28

### Fixed

- Spotify's play/pause button no longer flickers back to its old state while
  Spotify catches up after a click. Playback checks that began before the click
  can no longer overwrite the immediate button response either.

## [1.1.5] — 2026-07-28

### Added

- When macOS is blocking Beamhook from controlling an app, the menu now says so
  and offers a button to the right Settings pane, instead of quietly showing
  "system volume only" as though the app had no volume control. Denying that
  permission only costs the volume slider — the media keys keep working.

### Removed

- TIDAL, which was added in 1.1.4 but does not actually respond. Its menu is
  readable, but pressing its playback items has no effect, and a target that
  ignores the keys is worse than one that isn't offered.

## [1.1.4] — 2026-07-28

### Added

- Five new targets that have no AppleScript at all: IINA, Amazon Music, TIDAL,
  Plexamp, and Deezer. Beamhook drives them by pressing their own menu items in
  the background — the app never comes forward and nothing is typed into it. Only
  IINA has been tested so far; if one of the others does nothing when you press
  play, please open an issue. These targets have no volume slider, because a menu
  can only step the volume rather than set it.
- The menu bar icon now shows what you have hooked, with a badge for Safari,
  Chrome, YouTube, Spotify, and Apple Music. Anything else keeps the plain hook.
- A help page at [beamhook.app/help](https://beamhook.app/help) walks through
  enabling "Allow JavaScript from Apple Events" in Safari and Chrome, with
  pictures. The browser notice in the menu links straight to it.

## [1.1.3] — 2026-07-27

### Changed

- Browser media controls respond noticeably faster. Beamhook now checks the tab
  it last saw a source in before falling back to searching every open tab, so
  play/pause and the volume sliders act straight away instead of after a scan.
- Media keys aimed at a hooked browser take the same fast path, so pressing
  pause reaches the tab without waiting on a full scan first.

### Fixed

- Pressing play/pause twice in quick succession no longer sends two commands.
  The button now ignores further presses until the one in flight finishes, so a
  double-press can't toggle a source back to where it started.

## [1.1.2] — 2026-07-27

### Fixed

- Video calls in Safari and Chrome — Google Meet, Teams, Discord and the like —
  no longer offer a play/pause button. Pressing it only froze your own view of
  the call. Their volume slider stays, so you can still turn a meeting down.
- A call tab can no longer quietly claim the media keys. Because a meeting
  counts as "playing" for its whole duration, it could be picked as the hooked
  browser source ahead of the music you actually meant to control.

## [1.1.1] — 2026-07-25

### Fixed

- Browser controls now keep targeting the same media source when tabs or
  windows are reordered, and safely stop if that source navigates away.
- Invalid non-finite volume values from an app's AppleScript no longer crash
  Beamhook.
- Media-key routing state is synchronized between the menu and event-tap
  threads.

### Changed

- The chosen browser media source is now remembered for as long as that page
  stays open, instead of being saved by tab position. Reloading the page,
  navigating away, or quitting Beamhook clears the choice, and the menu falls
  back to whatever is playing — a stale position could previously control an
  unrelated tab.

### Security

- Official updates now require a signed appcast and verify the archive before
  extraction. Sparkle is pinned to 2.9.4 for reproducible release builds.
- Adding custom AppleScript now clearly warns that scripts run with the user's
  permissions and asks for confirmation before hooking the app.

## [1.1.0] — 2026-07-25

### Added

- **Automatic updates.** The official build now checks for updates in the
  background on launch and installs them via Sparkle. Builds made from source
  do not auto-update.
- **Per-tab volume sliders** for browser sources that are actively playing,
  when "Allow JavaScript from Apple Events" is enabled in the browser.

### Changed

- Volume sliders now appear for any scriptable app that is currently playing
  audio, whether or not it is the hooked target.

## [1.0.0] — 2026-07-23

First tagged release.

### What Beamhook does

Hooks your Mac's hardware media keys (play/pause, next, previous — and
optionally the volume keys) to **one app you choose**, so macOS can't redirect
them to Apple Music, a YouTube tab, or whichever player it last remembers.
Native apps are controlled via AppleScript; browser targets control the active
YouTube tab.

### Highlights

- Built-in targets: Spotify, Apple Music, Apple TV, Safari, Chrome, Brave,
  Arc, Vivaldi, VLC, VOX, QuickTime Player, and Downcast — plus custom apps
  with your own AppleScript commands.
- Per-app volume sliders for scriptable apps that are currently playing audio.
- Optional routing of the hardware volume keys to the hooked app; hold ⌘ with
  a volume key to adjust the Mac's system volume instead.
- **New:** an explicit "Nothing" target — unhook the media keys entirely and
  hand them back to macOS, and the choice survives relaunch.
- **New:** the on-screen HUD hints at ⌘+volume when the volume keys are
  hooked, and uses a contrasting light/dark appearance so it stays legible on
  any desktop (including macOS 26 glass).
- Menu-bar popover shows what's actually playing, pins the hooked app to the
  top of the list, and offers one-click Hook/Unhook per app.

Requires macOS 14.0 or later. The active-audio source list requires macOS 14.2.

[1.1.1]: https://github.com/ppixu/beamhook/releases/tag/v1.1.1
[1.1.0]: https://github.com/ppixu/beamhook/releases/tag/v1.1.0
[1.0.0]: https://github.com/ppixu/beamhook/releases/tag/v1.0.0
