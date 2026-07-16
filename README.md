<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/icon-dark.png">
    <img src="docs/icon.png" width="88" height="88" alt="Beamhook">
  </picture>
</p>

<h1 align="center">Beamhook</h1>

<p align="center">Your media keys, hooked to the app you meant.</p>

<p align="center">
  <a href="https://ppixu.github.io/beamhook/"><b>Website</b></a>
  &nbsp;•&nbsp;
  <a href="https://ppixu.gumroad.com/l/beamhook"><b>Buy on Gumroad (€2)</b></a>
</p>

---

A tiny macOS menu-bar app that sends the hardware media keys
(play/pause/next/previous) to **one app you choose** — so Safari and Apple
Music can't hijack them. macOS 14+.

## Features

- Pick one target app — nothing else can steal the keys.
- Play/pause button that reflects what's actually playing.
- Volume sliders for scriptable apps while they're open.
- Built in: Spotify, Apple Music, Apple TV, Safari, Chrome, Brave, VLC, VOX,
  QuickTime, Downcast —
  or add any AppleScriptable app.

The browser targets control the active YouTube tab. Enable **Allow JavaScript
from Apple Events** in Safari's Develop menu or the Chromium browser's
View → Developer menu before using them.

## Build it yourself — free

```bash
git clone https://github.com/ppixu/beamhook
cd beamhook
brew install xcodegen
./run.sh
```

Then grant **Accessibility** when prompted, pick your app, and press play.

## Or download it — €2

Rather not build? A signed & notarized, ready-to-run build is **€2** on Gumroad — the same app, and it supports development.

[![Buy on Gumroad](https://img.shields.io/badge/Buy%20on-Gumroad-ff90e8?style=for-the-badge&logo=gumroad)](https://ppixu.gumroad.com/l/beamhook)

## License

[GPL-3.0](LICENSE). Use it, study it, change it, share it — derivative works
must stay under the GPL.
