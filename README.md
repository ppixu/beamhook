<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/mark-dark.svg">
    <img src="docs/mark.svg" width="720" alt="Previous, pause, Beamhook, play, and next symbols">
  </picture>
</p>

<h1 align="center">Beamhook</h1>

<p align="center">Hook your media keys to a specific app.</p>

<p align="center">
  <a href="https://beamhook.app/"><b>Website</b></a>
  &nbsp;•&nbsp;
  <a href="https://ppixu.gumroad.com/l/beamhook"><b>Get the official build (€5)</b></a>
  &nbsp;•&nbsp;
  <a href="https://github.com/ppixu/beamhook/issues"><b>Report a bug</b></a>
</p>

---

<p align="center">
  <img src="docs/demo.gif" width="720" alt="Demo: hooking the media keys to Spotify, then to Safari's YouTube tab, and back">
</p>

Beamhook makes your Mac's media keys predictable. It sends play/pause,
next, and previous to **one app you choose** — so macOS can't redirect them
to Apple Music, YouTube, or whichever player it remembers. It also lets you
control the volume of apps that are currently playing audio, when the app
supports AppleScript. Requires macOS 14.0 or later; the active-audio source list
requires macOS 14.2. Tested on macOS Tahoe 26.5.

> [!IMPORTANT]
> Firefox is not supported. Browser control works with Safari, Chrome, Brave,
> Arc, and Vivaldi.

## Features

- Hook the media keys to one target app — nothing else can steal them.
- Play/pause button that reflects what's actually playing.
- Volume sliders for scriptable apps that are currently playing audio, whether
  or not they are hooked.
- Per-tab volume sliders for actively playing browser sources when [JavaScript
  from Apple Events](https://beamhook.app/help/) is enabled.
- Optionally route the keyboard's volume keys to the selected app.
- Hold Command while pressing a volume key to adjust the Mac's system volume instead.
- If the hooked app isn't running, play/pause starts it and begins playback. Can
  be turned off in Settings. (A menu-driven app launched with an empty queue —
  TIDAL, for instance — has nothing to play.)
- Built in: Spotify, Apple Music, Apple TV, Safari, Chrome, Brave, Arc,
  Vivaldi, VLC, VOX, QuickTime Player, and Downcast.
- Also built in, driven through their menus rather than AppleScript: IINA,
  Amazon Music, Plexamp, and Deezer. IINA is tested; the other three are not yet
  — if one does nothing when you press play,
  [tell us](https://github.com/ppixu/beamhook/issues) and it can be fixed.
  These targets have no volume slider, because menus only step the volume.
- Add another app with your own AppleScript commands.

Some apps do not expose suitable AppleScript controls and cannot be controlled
this way.

The browser targets control the active YouTube tab. Enable **Allow JavaScript
from Apple Events** in Safari's Develop menu or the Chromium browser's
View → Developer menu before using them —
[step-by-step guide with pictures](https://beamhook.app/help/).

## Build it yourself — free

```bash
git clone https://github.com/ppixu/beamhook
cd beamhook
brew install xcodegen
./run.sh
```

Then grant **Accessibility** when prompted, pick your app, and press play.

## Or get the official build — €5

Rather not build it yourself? The **€5 one-time purchase** on Gumroad includes
the signed and notarized, ready-to-run app and all Beamhook 1.x updates. It is
the same complete app as the open-source version, and your purchase supports
continued development.

[![Get the official build on Gumroad](https://img.shields.io/badge/Official%20build-%E2%82%AC5-ff90e8?style=for-the-badge&logo=gumroad)](https://ppixu.gumroad.com/l/beamhook)

## Bugs and requests

Found a bug, or want an app supported that isn't in the list? Please open a
[GitHub issue](https://github.com/ppixu/beamhook/issues) — that's the place for
it, whether you bought the official build or built it yourself. Search the
[open issues](https://github.com/ppixu/beamhook/issues) first in case it's
already known, and include your macOS version, the Beamhook version, and the app
you were controlling.

## License

[GPL-3.0](LICENSE). Use it, study it, change it, share it — derivative works
must stay under the GPL.
