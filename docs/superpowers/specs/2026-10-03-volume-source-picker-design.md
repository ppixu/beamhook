# Pick whose volume the keys control, from the volume HUD — Design

**Date:** 2026-10-03
**Status:** Approved for planning

## Problem

The volume keys can only ever drive the hooked target. To change Spotify's
volume while a YouTube tab is hooked, the user has to open the menu and drag a
slider. Muting one app or tab is not possible from the keyboard at all: the mute
key always goes to macOS and silences everything.

Wanted: while Beamhook's volume overlay is on screen, ⌘↑ / ⌘↓ moves through the
apps and tabs that are playing, the volume keys then act on the chosen one, and
⌘ + Mute mutes or unmutes it.

## Behavior

### Key table

| Keys | Volume hook ON for target | Volume hook OFF |
|---|---|---|
| Vol ↑/↓ | target volume + Beamhook HUD (unchanged) | macOS (unchanged) |
| ⌘ + Vol ↑/↓ | macOS (unchanged) | **new:** target volume + Beamhook HUD |
| Mute | macOS (unchanged) | macOS (unchanged) |
| ⌘ + Mute | **new:** toggle mute of the volume source + HUD | same |
| ⌘ + ↑/↓ | **new, only while the volume HUD is visible:** expand to the source list, move the selection | same |

In words: ⌘ flips whatever the volume keys do for this target. With the hook on,
⌘ reaches the system volume (today's escape hatch); with the hook off, ⌘ reaches
the app.

- **⌘ + PgUp / PgDn** are accepted as quiet aliases for ⌘↑ / ⌘↓ (external
  keyboards). The HUD only ever advertises the arrows.
- **Only the volume HUD arms ⌘↑/↓.** The hooked, launching, play/pause and
  passthrough presentations do not. Outside that window Beamhook does not see
  ordinary keystrokes at all, exactly as today.
- **Exact modifiers.** ⌘↑/↓ match only with ⌘ and none of ⌃ ⌥ ⇧, so ⌘⇧↑
  (select to start) is never taken. The fn and numeric-pad flags that arrow and
  page keys carry are ignored.
- **Target with no scriptable volume** (menu-driven apps, a browser with no
  volume-capable tab): ⌘ + Vol and ⌘ + Mute pass through to macOS as they do
  today. Beamhook never swallows a key it can't act on.

### The volume session

Pressing ⌘↑ or ⌘↓ starts a *session*:

- The HUD grows from today's single bar into the source list (below), with the
  selection moved one row.
- **While the session lasts, every volume key — with or without ⌘ — goes to the
  selected source, and so does ⌘ + Mute.** Without this rule a user still holding
  ⌘ after picking would hit the system volume with the hook on, which reads as
  the picker not working.
- The session ends when the HUD hides: 2.5 s after the last key while the list is
  shown (today's single-bar HUD keeps its 1.5 s). The next volume press starts
  from the hooked target again. The pick never persists and never changes the
  hooked target — play/pause/next keep going where they went.

### Sources

Built when the session starts, in this order, capped at 6 rows:

1. The hooked target, if it has scriptable volume. A browser target contributes
   its selected tab.
2. Other running apps with a live Core Audio output stream whose definition
   supports volume (`AudioProcessMonitor`, one refresh at session start). On
   macOS 14.0–14.1, where that monitor is unavailable, this group is empty.
3. Browser tabs with a volume, from `refreshActiveBrowserMedia` (Apple events, on
   `pollRunner`). The list appears without them; they are appended when the scan
   returns. The selection is kept by source id across that refresh.

Selection wraps at both ends. The list is never empty: the picker only arms
while a volume HUD is up, and that HUD only appears after a volume change or mute
on the hooked target, so the target is always row 1. With a single source, ⌘↑/↓
still expands the HUD (showing that nothing else is playing) and is swallowed.

### Mute

⌘ + Mute toggles the current volume source — the selected source during a
session, otherwise the hooked target:

- Volume > 0 → remember it, set 0.
- Volume 0 with a remembered value → restore it, forget it.
- Volume 0 with nothing remembered (Beamhook restarted while muted, or the user
  dragged it to 0) → restore to 50.

Same mechanism for apps and tabs: set-volume through the existing scripts, no
per-app mute properties. Memory is in-process only.

## HUD

Compact (today's volume presentation), shown for every Beamhook volume change
outside a session:

```
  Spotify
  ⌘ + 🔊 for system volume          ← only when the hook is ON (today's line)
  ⌘ ↑↓ switch · ⌘ 🔇 mute           ← new hint line
  🔈 ━━━━━━━━━━━━━━──────── 🔊
```

Reached via ⌘ + Vol (hook off), the first hint line is hidden — plain volume is
already the system volume.

Expanded (during a session):

```
    Music        ━━━━━─────────
  ▸ Spotify      ━━━━━━━━━━────
    YouTube – C  ━━━━━━━━━━━━━━
    Twitch – S   🔇 muted
  ⌘ ↑↓ switch · ⌘ 🔇 mute
```

- One row per source: name (truncating; tabs show the tab label plus a short
  browser suffix), a mini bar or "muted", and a highlighted background plus ▸ on
  the selected row.
- Row volumes come from the caches (`volumeByBundle`, candidate `.volume`) and
  are refreshed off-main on `pollRunner` when the session starts; a row with no
  known volume yet shows an empty track.
- The speaker in the hint is an SF Symbol (`speaker.slash.fill`), matching the
  existing hint row — no emoji.
- VoiceOver: each row reads "<name>, <percent> percent" or "<name>, muted"; the
  selected row adds "selected".

## Architecture

### BeamhookKit (pure, unit-tested)

- **`VolumeKeyAction`** — `resolve(key:command:hijacked:targetHasVolume:sessionActive:)`
  returns `.appVolume(up:)`, `.toggleMute`, or `.passThrough`. The whole key table
  above lives here; `MediaKeyTap` asks it instead of branching inline.
- **`VolumeSource`** — `.app(bundleID:)` / `.browserTab(id:)` with `id` and display
  name.
- **`VolumeSourceList`** — builds the ordered, capped list from the three groups,
  `selectNext()` / `selectPrevious()` with wrap, and `replaceSources(_:)` that
  keeps the selection by id (falls back to the neighbouring index when the
  selected source vanished).
- **`MuteMemory`** — `toggle(sourceID:current:) -> Int` implementing the three
  mute rules.
- **`SourcePickerKey`** — `match(keyCode:flags:) -> .previous / .next / nil`
  (126/116 → previous, 125/121 → next; exactly ⌘).

### App target

- **`MediaKeyTap`** — two more lock-protected flags, `targetHasVolume` and
  `volumeSessionActive`. The volume and mute branch calls
  `VolumeKeyAction.resolve`. On `.appVolume` / `.toggleMute` it swallows the
  event and calls the handler with `.volumeUp` / `.volumeDown` / `.mute`; plain
  mute never reaches the handler, so `.mute` there always means "toggle source
  mute". On `.passThrough` with ⌘ held on a volume key, it strips ⌘ as today.
- **`SourcePickerKeyTap`** (new, `System/`) — a keyDown-only `CGEventTap` on its
  own thread, created by `start()` and fully torn down by `stop()`. Swallows
  events `SourcePickerKey.match` accepts and hands them to a main-thread handler;
  everything else is returned untouched. Re-enables itself on
  `tapDisabledByTimeout`. Creation failure is logged and leaves the picker inert.
- **`AppState`** — owns a `VolumeSession?` (source list, mute memory lives on
  `AppState` so it outlives sessions). The volume drain applies steps to the
  current volume source: the hooked target through `TargetManager` as today, an
  app through the registry's `setVolume`, a tab through
  `browserMediaController.setVolume`, all on `scripting`. Arms the picker tap when
  a volume HUD shows; starts the session on the first ⌘↑/↓; ends both on the
  HUD's hide callback. Keeps `tap.targetHasVolume` in step with the target in
  `updateVolumeHijack()`.
- **`HookHUD`** — new presentation `.volumeSources(rows:selectedIndex:)`, the new
  hint line on `.volume`, a flag on `.volume` saying whether the "for system
  volume" line applies, and an `onHide` callback fired from `dismiss` (only for
  the generation it belongs to).

## Errors

- A source quits or its tab closes mid-session: the set fails silently; it drops
  out on the next list refresh and the selection moves to its neighbour.
- Browser "JavaScript from Apple Events" off: that browser's tabs don't appear.
  No error HUD.
- Picker tap can't be created: HUD and volume work; ⌘↑/↓ is inert; logged.

## Testing

No Xcode on the dev Mac, so BeamhookKit logic is verified with a `swiftc`
typecheck plus a scratchpad harness; the XCTest files are still written so CI
and an Xcode machine run them.

- `VolumeKeyActionTests` — every row of the key table, plus session overrides
  and no-volume pass-through.
- `VolumeSourceListTests` — order, cap of 6, wrap, selection kept across a
  refresh that appends tabs, neighbour fallback when the selection vanishes.
- `MuteMemoryTests` — the three mute rules.
- `SourcePickerKeyTests` — arrows and page keys with ⌘; rejects ⌘⇧/⌘⌥/⌘⌃ and
  bare arrows; ignores fn/numeric-pad flags.
- `MediaKeyTapTests` — ⌘ + Mute swallowed only with `targetHasVolume`; ⌘ + Vol
  routed with the hook off; session routes plain and ⌘ volume keys to the
  handler.
- Manual on a real Mac: HUD layout light/dark, the list expanding, tabs appearing
  late, mute/unmute, the tap disarming after the HUD hides (⌘↑ in Finder works
  again).

## Docs

README key table, CHANGELOG entry, the website's shortcuts section.
