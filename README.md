<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/icon-dark.png">
    <img src="docs/icon.png" width="88" height="88" alt="Beamhook">
  </picture>
</p>

<h1 align="center">Beamhook</h1>

<p align="center">Your media keys, hooked to the app you meant.</p>

<p align="center"><a href="https://ppixu.github.io/beamhook/">Website</a></p>

---

A tiny macOS menu-bar app that captures the hardware media keys and sends
play/pause/next/previous to the **one app you choose** — so Safari and Apple
Music can't hijack them.

## Features

- Pick one target app — nothing else can steal the keys.
- Play/pause button reflects what's actually playing.
- Volume sliders for the scriptable apps currently making sound.
- Built in: Spotify, Apple Music, Apple TV, VLC, VOX, QuickTime, Downcast —
  or add any AppleScriptable app.

## Install

```bash
git clone https://github.com/ppixu/beamhook
cd beamhook
brew install xcodegen
./run.sh
```

Then grant **Accessibility** when prompted, pick your app, and press play.
Requires macOS 14+.

## Download

Building from source (above) is free. If you'd rather not, a signed &
notarized, ready-to-run build is **$5** on
[Gumroad](https://ppixu.gumroad.com/l/beamhook) — same app, and it supports
development.

## License

[GPL-3.0](LICENSE). Use it, study it, change it, share it — derivative works
must stay under the GPL.
