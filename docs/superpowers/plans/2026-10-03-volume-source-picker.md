# Volume source picker — Implementation Plan

> **Superseded in part by the 1.2.1 merge.** The key routing and the app mute described below were replaced when this branch merged upstream 1.2.1: routing lives in `VolumeKeyRouting.destination` / `VolumeKeyRouting.muteDestination` (there is no `VolumeKeyAction`), apps are muted through `ProcessMuteController` (not volume 0), plain Mute follows upstream's rule rather than always going to macOS, and `MuteMemory` is used for browser tabs only. The body is kept as written.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** While Beamhook's volume HUD is visible, ⌘↑/⌘↓ expands it into a list of playing apps and tabs and picks whose volume the keys change; ⌘+Mute mutes/unmutes the current source; ⌘+Volume reaches the app when the volume hook is off.

**Architecture:** Pure decisions live in BeamhookKit (`VolumeKeyAction`, `SourcePickerKey`, `VolumeSourceList`, `MuteMemory`, a read-modify-write `TargetManager.updateVolume`). The app target gets a short-lived keyboard tap (`SourcePickerKeyTap`) armed only while a volume HUD is up, a `MediaKeyTap` that asks `VolumeKeyAction` what to do with volume/mute keys, a `HookHUD` with a source-list presentation, and `AppState` wiring that owns the session.

**Tech Stack:** Swift 5, AppKit, CoreGraphics event taps, macOS 14+, XCTest, XcodeGen.

**Spec:** `docs/superpowers/specs/2026-10-03-volume-source-picker-design.md`

## Global Constraints

- **Never call AppleScript on the main thread.** Every `NSAppleScript` / `currentVolume()` / `setVolume()` call goes through a `ScriptRunning` off-main queue: `scripting` for user actions, `pollRunner` for background reads. Blocking main caused the July 2026 system freeze.
- **Kit code (`Sources/BeamhookKit/`) must not import AppKit or CoreGraphics** and makes no system calls. Only `import Foundation`.
- **Deployment target macOS 14.0**, `SWIFT_VERSION 5.0`. `AudioProcessMonitor` is `@available(macOS 14.2, *)`.
- **Beamhook must never see ordinary keystrokes outside the volume HUD window.** The keyboard tap exists only between `arm()` and `disarm()`.
- **Exact key codes** (Carbon `Events.h`): ↑ 126, ↓ 125, PgUp 116, PgDn 121. Media key codes (`ev_keymap.h`): volume up 0, volume down 1, mute 7.
- **Copy:** hint line text is exactly `⌘ ↑↓ switch · ⌘` + `speaker.slash.fill` symbol + `mute`. Muted row text is `muted`. Tab rows are named `"<tab label> · <browser applicationName>"`.
- **Session HUD hide delay 2.5 s; compact volume HUD stays 1.5 s. Source list cap: 6 rows. Unmute fallback: 50.**
- **Do not touch** `docs/index.html`, `docs/sitemap.xml`, `.gitignore` — they hold the user's own uncommitted edits. Always `git add` explicit paths, never `git add -A` / `git add .`.
- **Verification.** The suites run with `xcodegen generate` and `xcodebuild test -project Beamhook.xcodeproj -scheme BeamhookKit|Beamhook -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`. The per-step commands below use a local XCTest shim harness instead (proven against the existing suites — 104 Kit tests + 4 MediaKeyTap tests pass):
  - `$H/run-kit-tests.sh <TestFile.swift>...` — compiles all of `Sources/BeamhookKit` + `Tests/BeamhookKitTests/Mocks.swift` + the given XCTest files against an XCTest shim and runs every `func test*` (sync and async). Prefix with `APP_SOURCES="Sources/Beamhook/System/X.swift ..."` to also compile app-target files (for `Tests/BeamhookTests/*` tests). Prints `N tests run` then `ALL PASSED` or failures; exit status 1 on failure.
  - `$H/typecheck-app.sh` — typechecks the whole app target against BeamhookKit. Prints `APP TYPECHECK OK`.
  - where `$H` is the harness directory. Run both from the repo root.
- Commits: message style is a plain imperative sentence (see `git log`), ending with the line `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. If a commit fails on `index.lock` (parallel workers), wait a second and retry.

## File Structure

**Created**

| File | Responsibility |
|---|---|
| `Sources/BeamhookKit/VolumeKeyAction.swift` | The spec's key table: what the media tap does with a volume/mute key. |
| `Sources/BeamhookKit/SourcePickerKey.swift` | Which keystrokes are ⌘↑/⌘↓ (and the PgUp/PgDn aliases). |
| `Sources/BeamhookKit/VolumeSourceList.swift` | `VolumeSource`, `VolumeSourceEntry`, the ordered/capped/wrapping list. |
| `Sources/BeamhookKit/MuteMemory.swift` | Mute toggle rules and pre-mute volume memory. |
| `Sources/Beamhook/System/SourcePickerKeyTap.swift` | Keyboard tap that exists only while armed. |
| `Tests/BeamhookKitTests/VolumeKeyActionTests.swift` | |
| `Tests/BeamhookKitTests/SourcePickerKeyTests.swift` | |
| `Tests/BeamhookKitTests/VolumeSourceListTests.swift` | |
| `Tests/BeamhookKitTests/MuteMemoryTests.swift` | |
| `Tests/BeamhookTests/SourcePickerKeyTapTests.swift` | |

**Modified:** `Sources/BeamhookKit/TargetManager.swift`, `Sources/BeamhookKit/MediaKey.swift` (comment only), `Sources/Beamhook/System/MediaKeyTap.swift`, `Sources/Beamhook/UI/HookHUD.swift`, `Sources/Beamhook/AppState.swift`, `Tests/BeamhookKitTests/TargetManagerTests.swift`, `Tests/BeamhookTests/MediaKeyTapTests.swift`, `README.md`, `CHANGELOG.md`.

## Task order and parallelism

- Tasks 1, 2, 3 (Kit), 5 (picker tap) and 6 (HUD) are independent of each other.
- Task 4 (MediaKeyTap) needs Task 1. Task 5 needs Task 1 (`SourcePickerKey`).
- Task 7 (AppState) needs 1–6. Task 8 (docs) needs 7.
- Wave A: 1, 2, 3, 6 in parallel. Wave B: 4, 5 in parallel. Wave C: 7. Wave D: 8.

---

### Task 1: `VolumeKeyAction` and `SourcePickerKey` (BeamhookKit)

**Files:**
- Create: `Sources/BeamhookKit/VolumeKeyAction.swift`
- Create: `Sources/BeamhookKit/SourcePickerKey.swift`
- Create: `Tests/BeamhookKitTests/VolumeKeyActionTests.swift`
- Create: `Tests/BeamhookKitTests/SourcePickerKeyTests.swift`

**Interfaces:**
- Consumes: `MediaKey` from `Sources/BeamhookKit/MediaKey.swift`.
- Produces:
  - `public enum VolumeKeyAction: Equatable, Sendable { case handle, passThrough, passThroughWithoutCommand }`
  - `public static func VolumeKeyAction.resolve(key: MediaKey, commandHeld: Bool, hijacked: Bool, targetHasVolume: Bool, sessionActive: Bool) -> VolumeKeyAction`
  - `public enum SourcePickerKey: Equatable, Sendable { case previous, next }`
  - `public static func SourcePickerKey.match(keyCode: Int, command: Bool, shift: Bool, option: Bool, control: Bool) -> SourcePickerKey?`

- [ ] **Step 1: Write the failing tests**

`Tests/BeamhookKitTests/VolumeKeyActionTests.swift`:

```swift
import XCTest
@testable import BeamhookKit

final class VolumeKeyActionTests: XCTestCase {
    private func resolve(_ key: MediaKey, command: Bool = false, hijacked: Bool = false,
                         targetHasVolume: Bool = true, session: Bool = false) -> VolumeKeyAction {
        VolumeKeyAction.resolve(key: key, commandHeld: command, hijacked: hijacked,
                                targetHasVolume: targetHasVolume, sessionActive: session)
    }

    // Hook ON: plain volume is the app, ⌘ is today's escape hatch to the system.
    func testHookOnPlainVolumeIsHandled() {
        XCTAssertEqual(resolve(.volumeUp, hijacked: true), .handle)
        XCTAssertEqual(resolve(.volumeDown, hijacked: true), .handle)
    }

    func testHookOnCommandVolumeGoesToSystemWithoutCommand() {
        XCTAssertEqual(resolve(.volumeUp, command: true, hijacked: true), .passThroughWithoutCommand)
    }

    // Hook OFF: ⌘ flips it — the app gets ⌘+volume.
    func testHookOffPlainVolumePassesThrough() {
        XCTAssertEqual(resolve(.volumeUp), .passThrough)
    }

    func testHookOffCommandVolumeIsHandled() {
        XCTAssertEqual(resolve(.volumeDown, command: true), .handle)
    }

    func testHookOffCommandVolumePassesThroughWhenTargetHasNoVolume() {
        XCTAssertEqual(resolve(.volumeUp, command: true, targetHasVolume: false), .passThrough)
    }

    // Mute: plain mute is always the system's.
    func testPlainMuteAlwaysPassesThrough() {
        XCTAssertEqual(resolve(.mute), .passThrough)
        XCTAssertEqual(resolve(.mute, hijacked: true), .passThrough)
        XCTAssertEqual(resolve(.mute, session: true), .passThrough)
    }

    func testCommandMuteIsHandledWhenTargetHasVolume() {
        XCTAssertEqual(resolve(.mute, command: true), .handle)
        XCTAssertEqual(resolve(.mute, command: true, hijacked: true), .handle)
    }

    func testCommandMutePassesThroughWhenTargetHasNoVolume() {
        XCTAssertEqual(resolve(.mute, command: true, targetHasVolume: false), .passThrough)
    }

    // Session: every volume key follows the picked source.
    func testSessionHandlesVolumeWithAndWithoutCommand() {
        XCTAssertEqual(resolve(.volumeUp, session: true), .handle)
        XCTAssertEqual(resolve(.volumeUp, command: true, hijacked: true, session: true), .handle)
        XCTAssertEqual(resolve(.volumeDown, command: true, targetHasVolume: false, session: true), .handle)
    }

    func testSessionHandlesCommandMuteEvenWithoutTargetVolume() {
        XCTAssertEqual(resolve(.mute, command: true, targetHasVolume: false, session: true), .handle)
    }

    func testOtherKeysPassThrough() {
        XCTAssertEqual(resolve(.playPause, command: true, hijacked: true, session: true), .passThrough)
        XCTAssertEqual(resolve(.fastForward, command: true, session: true), .passThrough)
    }
}
```

`Tests/BeamhookKitTests/SourcePickerKeyTests.swift`:

```swift
import XCTest
@testable import BeamhookKit

final class SourcePickerKeyTests: XCTestCase {
    private func match(_ keyCode: Int, command: Bool = true, shift: Bool = false,
                       option: Bool = false, control: Bool = false) -> SourcePickerKey? {
        SourcePickerKey.match(keyCode: keyCode, command: command, shift: shift,
                              option: option, control: control)
    }

    func testCommandArrowsMatch() {
        XCTAssertEqual(match(126), .previous)   // ↑
        XCTAssertEqual(match(125), .next)       // ↓
    }

    func testCommandPageKeysAreAliases() {
        XCTAssertEqual(match(116), .previous)   // PgUp
        XCTAssertEqual(match(121), .next)       // PgDn
    }

    func testBareArrowsDoNotMatch() {
        XCTAssertNil(match(126, command: false))
        XCTAssertNil(match(125, command: false))
    }

    func testExtraModifiersDoNotMatch() {
        XCTAssertNil(match(126, shift: true))    // ⌘⇧↑ = select to start
        XCTAssertNil(match(125, option: true))
        XCTAssertNil(match(126, control: true))
    }

    func testOtherKeysDoNotMatch() {
        XCTAssertNil(match(123))   // ←
        XCTAssertNil(match(124))   // →
        XCTAssertNil(match(0))     // A
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `$H/run-kit-tests.sh Tests/BeamhookKitTests/VolumeKeyActionTests.swift Tests/BeamhookKitTests/SourcePickerKeyTests.swift`
Expected: compile errors `cannot find 'VolumeKeyAction' in scope` / `cannot find 'SourcePickerKey' in scope`.

- [ ] **Step 3: Implement**

`Sources/BeamhookKit/VolumeKeyAction.swift`:

```swift
import Foundation

/// What the media-key tap does with a volume or mute key. The whole key table
/// lives here so `MediaKeyTap` asks one question instead of branching inline:
///
/// | Keys        | Hook ON                         | Hook OFF                  |
/// |-------------|---------------------------------|---------------------------|
/// | Vol         | handle                          | pass through              |
/// | ⌘ + Vol     | pass through, minus ⌘           | handle (target has volume)|
/// | Mute        | pass through                    | pass through              |
/// | ⌘ + Mute    | handle (target has volume)      | same                      |
///
/// While a volume session is active (the source list is on screen), every
/// volume key and ⌘ + Mute is handled, so a user still holding ⌘ after picking
/// a source doesn't fall through to the system volume.
public enum VolumeKeyAction: Equatable, Sendable {
    /// Swallow the event and hand the key to Beamhook.
    case handle
    /// Let macOS have the event unchanged.
    case passThrough
    /// Let macOS have it with ⌘ removed, so it lands as an ordinary volume key
    /// rather than a modified shortcut.
    case passThroughWithoutCommand

    /// - Parameters:
    ///   - key: the decoded media key. Anything but volume up/down and mute passes through.
    ///   - commandHeld: ⌘ is down.
    ///   - hijacked: the user turned the volume hook on for the hooked target.
    ///   - targetHasVolume: the hooked target's volume can be set right now.
    ///   - sessionActive: the source list is on screen.
    public static func resolve(key: MediaKey, commandHeld: Bool, hijacked: Bool,
                               targetHasVolume: Bool, sessionActive: Bool) -> VolumeKeyAction {
        switch key {
        case .mute:
            guard commandHeld, targetHasVolume || sessionActive else { return .passThrough }
            return .handle
        case .volumeUp, .volumeDown:
            if sessionActive { return .handle }
            if hijacked { return commandHeld ? .passThroughWithoutCommand : .handle }
            return commandHeld && targetHasVolume ? .handle : .passThrough
        default:
            return .passThrough
        }
    }
}
```

`Sources/BeamhookKit/SourcePickerKey.swift`:

```swift
import Foundation

/// A keystroke that moves the volume-source picker. ⌘↑ / ⌘↓ are the advertised
/// keys; ⌘PgUp / ⌘PgDn are quiet aliases for external keyboards. Anything with
/// ⇧, ⌥ or ⌃ as well is left alone — ⌘⇧↑ is "select to start" in every editor.
public enum SourcePickerKey: Equatable, Sendable {
    case previous, next

    /// Virtual key codes from Carbon's HIToolbox `Events.h`.
    private static let upArrow = 126, downArrow = 125, pageUp = 116, pageDown = 121

    /// The fn and numeric-pad flags that arrow and page keys carry are not
    /// parameters on purpose: they say nothing about intent and must be ignored.
    public static func match(keyCode: Int, command: Bool, shift: Bool,
                             option: Bool, control: Bool) -> SourcePickerKey? {
        guard command, !shift, !option, !control else { return nil }
        switch keyCode {
        case upArrow, pageUp: return .previous
        case downArrow, pageDown: return .next
        default: return nil
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `$H/run-kit-tests.sh Tests/BeamhookKitTests/VolumeKeyActionTests.swift Tests/BeamhookKitTests/SourcePickerKeyTests.swift`
Expected: `16 tests run`, `ALL PASSED`.

- [ ] **Step 5: Commit**

```bash
git add Sources/BeamhookKit/VolumeKeyAction.swift Sources/BeamhookKit/SourcePickerKey.swift Tests/BeamhookKitTests/VolumeKeyActionTests.swift Tests/BeamhookKitTests/SourcePickerKeyTests.swift
git commit -m "Decide volume, mute and source-picker keys in BeamhookKit

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: `VolumeSourceList` and `MuteMemory` (BeamhookKit)

**Files:**
- Create: `Sources/BeamhookKit/VolumeSourceList.swift`
- Create: `Sources/BeamhookKit/MuteMemory.swift`
- Create: `Tests/BeamhookKitTests/VolumeSourceListTests.swift`
- Create: `Tests/BeamhookKitTests/MuteMemoryTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `public enum VolumeSource: Hashable, Sendable { case hookedTarget; case app(bundleID: String); case browserTab(id: String); public var id: String }` — ids are `"target"`, `"app:<bundleID>"`, `"tab:<id>"`.
  - `public struct VolumeSourceEntry: Equatable, Sendable { public let source: VolumeSource; public let name: String; public init(source: VolumeSource, name: String) }`
  - `public struct VolumeSourceList: Equatable, Sendable` with `public static let maxRows = 6`, `public private(set) var entries: [VolumeSourceEntry]`, `public private(set) var selectedIndex: Int`, `public var selected: VolumeSourceEntry?`, `public init(target: VolumeSourceEntry?, apps: [VolumeSourceEntry], tabs: [VolumeSourceEntry])`, `public mutating func selectNext()`, `public mutating func selectPrevious()`, `public mutating func replace(target: VolumeSourceEntry?, apps: [VolumeSourceEntry], tabs: [VolumeSourceEntry])`.
  - `public struct MuteMemory: Sendable` with `public static let fallbackRestore = 50`, `public init()`, `public func restoreVolume(for sourceID: String) -> Int`, `public static func toggled(from current: Int, restore: Int) -> Int`, `public mutating func record(sourceID: String, previous: Int, new: Int)`.

- [ ] **Step 1: Write the failing tests**

`Tests/BeamhookKitTests/VolumeSourceListTests.swift`:

```swift
import XCTest
@testable import BeamhookKit

final class VolumeSourceListTests: XCTestCase {
    private let target = VolumeSourceEntry(source: .hookedTarget, name: "Spotify")
    private func app(_ id: String) -> VolumeSourceEntry {
        VolumeSourceEntry(source: .app(bundleID: id), name: id)
    }
    private func tab(_ id: String) -> VolumeSourceEntry {
        VolumeSourceEntry(source: .browserTab(id: id), name: id)
    }

    func testIdsAreDistinctPerKind() {
        XCTAssertEqual(VolumeSource.hookedTarget.id, "target")
        XCTAssertEqual(VolumeSource.app(bundleID: "x").id, "app:x")
        XCTAssertEqual(VolumeSource.browserTab(id: "x").id, "tab:x")
    }

    func testOrderIsTargetThenAppsThenTabsAndStartsOnTarget() {
        let list = VolumeSourceList(target: target, apps: [app("music")], tabs: [tab("yt")])
        XCTAssertEqual(list.entries.map(\.name), ["Spotify", "music", "yt"])
        XCTAssertEqual(list.selectedIndex, 0)
        XCTAssertEqual(list.selected, target)
    }

    func testCapsAtSixRowsDroppingTabsFirst() {
        let list = VolumeSourceList(target: target,
                                    apps: [app("a1"), app("a2"), app("a3")],
                                    tabs: [tab("t1"), tab("t2"), tab("t3")])
        XCTAssertEqual(VolumeSourceList.maxRows, 6)
        XCTAssertEqual(list.entries.map(\.name), ["Spotify", "a1", "a2", "a3", "t1", "t2"])
    }

    func testDuplicateSourcesAreDropped() {
        let list = VolumeSourceList(target: target, apps: [app("a"), app("a")], tabs: [])
        XCTAssertEqual(list.entries.count, 2)
    }

    func testSelectionWrapsBothWays() {
        var list = VolumeSourceList(target: target, apps: [app("a")], tabs: [tab("t")])
        list.selectPrevious()
        XCTAssertEqual(list.selected?.name, "t")
        list.selectNext()
        XCTAssertEqual(list.selected?.name, "Spotify")
        list.selectNext()
        XCTAssertEqual(list.selected?.name, "a")
    }

    func testEmptyListIsInert() {
        var list = VolumeSourceList(target: nil, apps: [], tabs: [])
        list.selectNext()
        list.selectPrevious()
        XCTAssertNil(list.selected)
        XCTAssertEqual(list.selectedIndex, 0)
    }

    func testReplaceKeepsSelectionBySourceWhenTabsArrive() {
        var list = VolumeSourceList(target: target, apps: [app("a"), app("b")], tabs: [])
        list.selectNext()
        list.selectNext()   // "b"
        list.replace(target: target, apps: [app("a"), app("b")], tabs: [tab("t")])
        XCTAssertEqual(list.selected?.name, "b")
        XCTAssertEqual(list.entries.count, 4)
    }

    func testReplaceFollowsSelectionWhenRowsReorder() {
        var list = VolumeSourceList(target: target, apps: [app("a"), app("b")], tabs: [])
        list.selectNext()   // "a"
        list.replace(target: target, apps: [app("b"), app("a")], tabs: [])
        XCTAssertEqual(list.selected?.name, "a")
        XCTAssertEqual(list.selectedIndex, 2)
    }

    func testReplaceFallsBackToNeighbourWhenSelectionVanishes() {
        var list = VolumeSourceList(target: target, apps: [app("a"), app("b")], tabs: [])
        list.selectPrevious()   // "b", index 2
        list.replace(target: target, apps: [app("a")], tabs: [])
        XCTAssertEqual(list.selectedIndex, 1)
        XCTAssertEqual(list.selected?.name, "a")
    }

    func testReplaceWithNothingResetsToZero() {
        var list = VolumeSourceList(target: target, apps: [app("a")], tabs: [])
        list.selectNext()
        list.replace(target: nil, apps: [], tabs: [])
        XCTAssertEqual(list.selectedIndex, 0)
        XCTAssertNil(list.selected)
    }
}
```

`Tests/BeamhookKitTests/MuteMemoryTests.swift`:

```swift
import XCTest
@testable import BeamhookKit

final class MuteMemoryTests: XCTestCase {
    func testAudibleTogglesToZero() {
        XCTAssertEqual(MuteMemory.toggled(from: 40, restore: 70), 0)
    }

    func testSilentTogglesToRestore() {
        XCTAssertEqual(MuteMemory.toggled(from: 0, restore: 70), 70)
    }

    func testRestoreFallsBackToFiftyWhenNothingRemembered() {
        let memory = MuteMemory()
        XCTAssertEqual(MuteMemory.fallbackRestore, 50)
        XCTAssertEqual(memory.restoreVolume(for: "app:x"), 50)
    }

    func testMuteThenUnmuteRestoresThePreviousVolume() {
        var memory = MuteMemory()
        memory.record(sourceID: "app:x", previous: 40, new: 0)
        XCTAssertEqual(memory.restoreVolume(for: "app:x"), 40)
        memory.record(sourceID: "app:x", previous: 0, new: 40)
        XCTAssertEqual(memory.restoreVolume(for: "app:x"), 50, "an unmute forgets the value")
    }

    func testSourcesAreRememberedSeparately() {
        var memory = MuteMemory()
        memory.record(sourceID: "app:x", previous: 30, new: 0)
        memory.record(sourceID: "tab:y", previous: 80, new: 0)
        XCTAssertEqual(memory.restoreVolume(for: "app:x"), 30)
        XCTAssertEqual(memory.restoreVolume(for: "tab:y"), 80)
    }

    func testMutingAnAlreadySilentSourceRemembersNothing() {
        var memory = MuteMemory()
        memory.record(sourceID: "app:x", previous: 0, new: 0)
        XCTAssertEqual(memory.restoreVolume(for: "app:x"), 50)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `$H/run-kit-tests.sh Tests/BeamhookKitTests/VolumeSourceListTests.swift Tests/BeamhookKitTests/MuteMemoryTests.swift`
Expected: compile errors `cannot find 'VolumeSourceEntry' in scope` / `cannot find 'MuteMemory' in scope`.

- [ ] **Step 3: Implement**

`Sources/BeamhookKit/VolumeSourceList.swift`:

```swift
import Foundation

/// Something whose volume the volume keys can drive during a picker session.
public enum VolumeSource: Hashable, Sendable {
    /// Whatever is hooked — for a browser, its selected tab. Routed through
    /// `TargetManager` exactly like a volume key outside a session.
    case hookedTarget
    /// Another running app with a scriptable volume.
    case app(bundleID: String)
    /// A browser tab, by `BrowserMediaCandidate.id`.
    case browserTab(id: String)

    /// Stable across list refreshes; used to keep the selection and as the
    /// mute-memory key.
    public var id: String {
        switch self {
        case .hookedTarget: return "target"
        case .app(let bundleID): return "app:\(bundleID)"
        case .browserTab(let id): return "tab:\(id)"
        }
    }
}

public struct VolumeSourceEntry: Equatable, Sendable {
    public let source: VolumeSource
    public let name: String

    public init(source: VolumeSource, name: String) {
        self.source = source
        self.name = name
    }
}

/// The rows of the volume-source picker: the hooked target first, then other
/// playing apps, then browser tabs, capped so the HUD stays a glance. Selection
/// wraps at both ends and survives refreshes by source identity, because tabs
/// arrive a moment after the list first appears.
public struct VolumeSourceList: Equatable, Sendable {
    public static let maxRows = 6

    public private(set) var entries: [VolumeSourceEntry] = []
    public private(set) var selectedIndex = 0

    public var selected: VolumeSourceEntry? {
        entries.indices.contains(selectedIndex) ? entries[selectedIndex] : nil
    }

    public init(target: VolumeSourceEntry?, apps: [VolumeSourceEntry], tabs: [VolumeSourceEntry]) {
        entries = Self.ordered(target: target, apps: apps, tabs: tabs)
    }

    public mutating func selectNext() {
        guard !entries.isEmpty else { return }
        selectedIndex = (selectedIndex + 1) % entries.count
    }

    public mutating func selectPrevious() {
        guard !entries.isEmpty else { return }
        selectedIndex = (selectedIndex - 1 + entries.count) % entries.count
    }

    /// Swap in fresh rows, keeping the selected source if it is still listed and
    /// otherwise landing on the row that took its place.
    public mutating func replace(target: VolumeSourceEntry?, apps: [VolumeSourceEntry],
                                 tabs: [VolumeSourceEntry]) {
        let previous = selected?.source
        entries = Self.ordered(target: target, apps: apps, tabs: tabs)
        if let previous, let index = entries.firstIndex(where: { $0.source == previous }) {
            selectedIndex = index
        } else {
            selectedIndex = entries.isEmpty ? 0 : min(selectedIndex, entries.count - 1)
        }
    }

    private static func ordered(target: VolumeSourceEntry?, apps: [VolumeSourceEntry],
                                tabs: [VolumeSourceEntry]) -> [VolumeSourceEntry] {
        var seen = Set<VolumeSource>()
        let all = (target.map { [$0] } ?? []) + apps + tabs
        return Array(all.filter { seen.insert($0.source).inserted }.prefix(maxRows))
    }
}
```

`Sources/BeamhookKit/MuteMemory.swift`:

```swift
import Foundation

/// ⌘ + Mute toggles one source by setting its volume, not through per-app mute
/// properties (most apps have none). Muting remembers what it silenced so the
/// next toggle can put it back. In-process only: after a restart, or when the
/// user dragged a source to 0 themselves, unmuting restores `fallbackRestore`.
public struct MuteMemory: Sendable {
    public static let fallbackRestore = 50

    private var saved: [String: Int] = [:]

    public init() {}

    /// What unmuting `sourceID` restores to.
    public func restoreVolume(for sourceID: String) -> Int {
        saved[sourceID] ?? Self.fallbackRestore
    }

    /// The toggle itself: anything audible goes to 0, silence goes to `restore`.
    /// Static and pure so it can run inside an off-main read-modify-write.
    public static func toggled(from current: Int, restore: Int) -> Int {
        current > 0 ? 0 : restore
    }

    /// Record a completed toggle so the next one can undo it.
    public mutating func record(sourceID: String, previous: Int, new: Int) {
        if new == 0, previous > 0 {
            saved[sourceID] = previous
        } else {
            saved[sourceID] = nil
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `$H/run-kit-tests.sh Tests/BeamhookKitTests/VolumeSourceListTests.swift Tests/BeamhookKitTests/MuteMemoryTests.swift`
Expected: `16 tests run`, `ALL PASSED`.

- [ ] **Step 5: Commit**

```bash
git add Sources/BeamhookKit/VolumeSourceList.swift Sources/BeamhookKit/MuteMemory.swift Tests/BeamhookKitTests/VolumeSourceListTests.swift Tests/BeamhookKitTests/MuteMemoryTests.swift
git commit -m "Model the volume-source list and mute memory in BeamhookKit

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: Read-modify-write volume in `TargetManager` (BeamhookKit)

**Files:**
- Modify: `Sources/BeamhookKit/TargetManager.swift` (the `adjustVolume` section, ~lines 64–89)
- Modify: `Tests/BeamhookKitTests/TargetManagerTests.swift` (append to the `// MARK: - adjustVolume` section)

**Interfaces:**
- Consumes: `MediaApp`, `ScriptRunning`, the existing `currentTargetApp()` and `resolver`.
- Produces:
  - `public struct VolumeChange: Equatable, Sendable { public let bundleID: String; public let previous: Int; public let volume: Int }` (declare in `TargetManager.swift` above the class)
  - `public let volumeStep: Int` (was `private let`)
  - `public func updateVolume(_ transform: @escaping (Int) -> Int) async -> VolumeChange?` — hooked target
  - `public func updateVolume(ofBundleID bundleID: String, _ transform: @escaping (Int) -> Int) async -> VolumeChange?` — any registered app, hooked target unchanged
  - `adjustVolume(bySteps:)` keeps its exact signature and return type `(bundleID: String, volume: Int)?`.

- [ ] **Step 1: Write the failing tests**

Append inside `final class TargetManagerTests`, after the existing `adjustVolume` tests:

```swift
    // MARK: - updateVolume

    func testUpdateVolumeAppliesTransformAndReportsPrevious() async {
        let (resolver, app) = makeVolumeTarget(current: 40)
        let tm = makeManager(resolver: resolver)
        tm.selectedTargetID = "spotify"

        let change = await tm.updateVolume { _ in 0 }
        XCTAssertEqual(change, VolumeChange(bundleID: "com.example.spotify", previous: 40, volume: 0))
        XCTAssertEqual(app.setVolumeCalls, [0])
    }

    func testUpdateVolumeClamps() async {
        let (resolver, app) = makeVolumeTarget(current: 40)
        let tm = makeManager(resolver: resolver)
        tm.selectedTargetID = "spotify"

        let change = await tm.updateVolume { $0 + 500 }
        XCTAssertEqual(change?.volume, 100)
        XCTAssertEqual(app.setVolumeCalls, [100])
    }

    func testUpdateVolumeNoOpWithoutReadableVolume() async {
        let (resolver, app) = makeVolumeTarget(current: nil)
        let tm = makeManager(resolver: resolver)
        tm.selectedTargetID = "spotify"

        let change = await tm.updateVolume { $0 + 6 }
        XCTAssertNil(change)
        XCTAssertTrue(app.setVolumeCalls.isEmpty)
    }

    func testUpdateVolumeOfBundleIDLeavesTheHookedTargetAlone() async {
        let (resolver, spotify) = makeVolumeTarget(current: 50)
        let music = MockMediaApp(id: "music", isRunning: true)
        music.supportsVolume = true
        music.volumeValue = 20
        resolver.apps["music"] = music
        let tm = makeManager(resolver: resolver)
        tm.selectedTargetID = "spotify"

        let change = await tm.updateVolume(ofBundleID: "com.example.music") { $0 + 10 }
        XCTAssertEqual(change, VolumeChange(bundleID: "com.example.music", previous: 20, volume: 30))
        XCTAssertEqual(music.setVolumeCalls, [30])
        XCTAssertTrue(spotify.setVolumeCalls.isEmpty)
        XCTAssertEqual(tm.selectedTargetID, "spotify")
    }

    func testUpdateVolumeOfBundleIDNoOpForUnknownOrUnreadyApp() async {
        let resolver = MockResolver()
        let music = MockMediaApp(id: "music", isRunning: true)
        music.supportsVolume = true
        music.volumeValue = 20
        music.readyValue = false
        resolver.apps["music"] = music
        let tm = makeManager(resolver: resolver)

        let unknown = await tm.updateVolume(ofBundleID: "com.example.nope") { $0 + 10 }
        let unready = await tm.updateVolume(ofBundleID: "com.example.music") { $0 + 10 }
        XCTAssertNil(unknown)
        XCTAssertNil(unready)
        XCTAssertTrue(music.setVolumeCalls.isEmpty)
    }

    func testVolumeStepIsReadable() {
        let tm = makeManager(resolver: MockResolver(), volumeStep: 9)
        XCTAssertEqual(tm.volumeStep, 9)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `$H/run-kit-tests.sh Tests/BeamhookKitTests/TargetManagerTests.swift`
Expected: compile errors `value of type 'TargetManager' has no member 'updateVolume'` and `cannot find 'VolumeChange' in scope`.

- [ ] **Step 3: Implement**

In `Sources/BeamhookKit/TargetManager.swift`, add above `public final class TargetManager`:

```swift
/// One completed read-modify-write of an app's volume, 0...100.
public struct VolumeChange: Equatable, Sendable {
    public let bundleID: String
    public let previous: Int
    public let volume: Int

    public init(bundleID: String, previous: Int, volume: Int) {
        self.bundleID = bundleID
        self.previous = previous
        self.volume = volume
    }
}
```

Change `private let volumeStep: Int` to:

```swift
    /// Percent per volume-key press. Public so other volume sources (browser
    /// tabs) step by the same amount as the hooked target.
    public let volumeStep: Int
```

Replace the body of `adjustVolume(bySteps:)` (keep its doc comment and signature) with:

```swift
    public func adjustVolume(bySteps steps: Int) async -> (bundleID: String, volume: Int)? {
        guard steps != 0 else { return nil }
        let delta = steps * volumeStep
        guard let change = await updateVolume({ $0 + delta }) else { return nil }
        return (change.bundleID, change.volume)
    }
```

Add directly after it:

```swift
    /// Reads the hooked target's volume, sets `transform(current)` clamped to
    /// 0...100, and reports both — one off-main round-trip, so a mute toggle can
    /// decide from the live value without a second Apple event. nil when there's
    /// no target, it isn't ready, or it has no readable volume.
    public func updateVolume(_ transform: @escaping (Int) -> Int) async -> VolumeChange? {
        guard let app = currentTargetApp() else { return nil }
        return await Self.readModifyWrite(app, transform, on: runner)
    }

    /// Same as `updateVolume(_:)` for any registered app, without touching the
    /// hooked target. Used by the volume-source picker.
    public func updateVolume(ofBundleID bundleID: String,
                             _ transform: @escaping (Int) -> Int) async -> VolumeChange? {
        guard let app = resolver.allApps().first(where: { $0.bundleID == bundleID }) else { return nil }
        return await Self.readModifyWrite(app, transform, on: runner)
    }

    private static func readModifyWrite(_ app: MediaApp, _ transform: @escaping (Int) -> Int,
                                        on runner: ScriptRunning) async -> VolumeChange? {
        await runner.run {
            guard app.isReady, app.supportsVolume, let current = app.currentVolume() else { return nil }
            let next = min(100, max(0, transform(current)))
            app.setVolume(next)
            return VolumeChange(bundleID: app.bundleID, previous: current, volume: next)
        }
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `$H/run-kit-tests.sh Tests/BeamhookKitTests/TargetManagerTests.swift`
Expected: `ALL PASSED` (the existing `adjustVolume` tests must still pass unchanged).

Run: `$H/typecheck-app.sh`
Expected: `APP TYPECHECK OK`.

- [ ] **Step 5: Commit**

```bash
git add Sources/BeamhookKit/TargetManager.swift Tests/BeamhookKitTests/TargetManagerTests.swift
git commit -m "Let TargetManager read-modify-write any app's volume

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: `MediaKeyTap` routes volume and mute through `VolumeKeyAction`

**Depends on:** Task 1.

**Files:**
- Modify: `Sources/Beamhook/System/MediaKeyTap.swift` (`RoutingState`, new properties, the `if key.isVolume && volumeKeysHijacked` branch ~lines 141–158)
- Modify: `Sources/BeamhookKit/MediaKey.swift` (the `isVolume` doc comment only)
- Modify: `Tests/BeamhookTests/MediaKeyTapTests.swift`

**Interfaces:**
- Consumes: `VolumeKeyAction.resolve(key:commandHeld:hijacked:targetHasVolume:sessionActive:)`.
- Produces on `MediaKeyTap`:
  - `var targetHasVolume: Bool { get set }` (default `false`)
  - `var volumeSessionActive: Bool { get set }` (default `false`)
  - The handler now also receives `.mute`, meaning "toggle the volume source's mute". Plain mute never reaches it.

- [ ] **Step 1: Write the failing tests**

In `Tests/BeamhookTests/MediaKeyTapTests.swift`, change the `mediaKeyEvent` helper to accept flags:

```swift
    private func mediaKeyEvent(keyCode: Int, isDown: Bool, isRepeat: Bool = false,
                               command: Bool = false) -> CGEvent {
        let keyFlags = (isDown ? 0xA00 : 0xB00) | (isRepeat ? 0x1 : 0x0)
        let data1 = (keyCode << 16) | keyFlags
        let nsEvent = NSEvent.otherEvent(
            with: .systemDefined, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0, context: nil,
            subtype: Int16(MediaKeyDecoder.systemDefinedMediaKeysSubtype),
            data1: data1, data2: -1)!
        let event = nsEvent.cgEvent!
        if command { event.flags.insert(.maskCommand) }
        return event
    }
```

Extend `testRoutingFlagsSupportConcurrentReadersAndWriters` so the writer branch also sets `tap.targetHasVolume = index.isMultiple(of: 8)` and `tap.volumeSessionActive = index.isMultiple(of: 10)`, and the reader branch reads both.

Append at the end of the class:

```swift
    // MARK: - Volume and mute routing

    private func makeTap(handled: @escaping (MediaKey) -> Void) -> MediaKeyTap {
        MediaKeyTap(handler: handled)
    }

    func testCommandMuteIsSwallowedAndRoutedWhenTargetHasVolume() {
        var handled: [MediaKey] = []
        let tap = makeTap { handled.append($0) }
        tap.targetHasVolume = true

        let result = tap.handle(type: systemDefinedType,
                                event: mediaKeyEvent(keyCode: 7, isDown: true, command: true))

        XCTAssertNil(result)
        drainMainQueue()
        XCTAssertEqual(handled, [.mute])
    }

    func testCommandMutePassesThroughWhenTargetHasNoVolume() {
        var handled: [MediaKey] = []
        let tap = makeTap { handled.append($0) }
        tap.targetHasVolume = false

        let result = tap.handle(type: systemDefinedType,
                                event: mediaKeyEvent(keyCode: 7, isDown: true, command: true))

        XCTAssertNotNil(result)
        drainMainQueue()
        XCTAssertTrue(handled.isEmpty)
    }

    func testPlainMuteAlwaysReachesMacOS() {
        var handled: [MediaKey] = []
        let tap = makeTap { handled.append($0) }
        tap.targetHasVolume = true
        tap.volumeKeysHijacked = true
        tap.volumeSessionActive = true

        let result = tap.handle(type: systemDefinedType,
                                event: mediaKeyEvent(keyCode: 7, isDown: true))

        XCTAssertNotNil(result)
        drainMainQueue()
        XCTAssertTrue(handled.isEmpty)
    }

    func testHeldCommandMuteDoesNotFlapTheToggle() {
        var handled: [MediaKey] = []
        let tap = makeTap { handled.append($0) }
        tap.targetHasVolume = true

        let result = tap.handle(type: systemDefinedType,
                                event: mediaKeyEvent(keyCode: 7, isDown: true, isRepeat: true, command: true))

        XCTAssertNil(result, "still swallowed so macOS doesn't toggle system mute")
        drainMainQueue()
        XCTAssertTrue(handled.isEmpty, "a repeat must not toggle again")
    }

    func testCommandVolumeReachesTheAppWhenHookIsOff() {
        var handled: [MediaKey] = []
        let tap = makeTap { handled.append($0) }
        tap.volumeKeysHijacked = false
        tap.targetHasVolume = true

        let result = tap.handle(type: systemDefinedType,
                                event: mediaKeyEvent(keyCode: 0, isDown: true, command: true))

        XCTAssertNil(result)
        drainMainQueue()
        XCTAssertEqual(handled, [.volumeUp])
    }

    func testCommandVolumeStillReachesSystemWithoutCommandWhenHookIsOn() {
        var handled: [MediaKey] = []
        let tap = makeTap { handled.append($0) }
        tap.volumeKeysHijacked = true
        tap.targetHasVolume = true

        let event = mediaKeyEvent(keyCode: 1, isDown: true, command: true)
        let result = tap.handle(type: systemDefinedType, event: event)

        XCTAssertNotNil(result)
        XCTAssertFalse(event.flags.contains(.maskCommand), "⌘ is stripped before macOS sees it")
        drainMainQueue()
        XCTAssertTrue(handled.isEmpty)
    }

    func testSessionRoutesCommandVolumeEvenWithHookOn() {
        var handled: [MediaKey] = []
        let tap = makeTap { handled.append($0) }
        tap.volumeKeysHijacked = true
        tap.volumeSessionActive = true

        let result = tap.handle(type: systemDefinedType,
                                event: mediaKeyEvent(keyCode: 1, isDown: true, command: true))

        XCTAssertNil(result)
        drainMainQueue()
        XCTAssertEqual(handled, [.volumeDown])
    }

    func testHeldVolumeKeyStillRamps() {
        var handled: [MediaKey] = []
        let tap = makeTap { handled.append($0) }
        tap.volumeKeysHijacked = true

        _ = tap.handle(type: systemDefinedType,
                       event: mediaKeyEvent(keyCode: 0, isDown: true, isRepeat: true))

        drainMainQueue()
        XCTAssertEqual(handled, [.volumeUp])
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `APP_SOURCES="Sources/Beamhook/System/MediaKeyTap.swift" $H/run-kit-tests.sh Tests/BeamhookTests/MediaKeyTapTests.swift`
Expected: compile error `value of type 'MediaKeyTap' has no member 'targetHasVolume'`.

- [ ] **Step 3: Implement**

In `MediaKeyTap.swift`, extend `RoutingState`:

```swift
    private struct RoutingState {
        var transportKeysHijacked = true
        var volumeKeysHijacked = false
        var targetHasVolume = false
        var volumeSessionActive = false
    }
```

Add after the `volumeKeysHijacked` property:

```swift
    /// Whether the hooked target's volume can be set right now. Gates ⌘+Volume
    /// (hook off) and ⌘+Mute, so Beamhook never swallows a key it can't act on.
    var targetHasVolume: Bool {
        get { withStateLock { routingState.targetHasVolume } }
        set { withStateLock { routingState.targetHasVolume = newValue } }
    }

    /// True while the volume-source list is on screen: every volume key and
    /// ⌘+Mute then goes to the picked source, with or without ⌘.
    var volumeSessionActive: Bool {
        get { withStateLock { routingState.volumeSessionActive } }
        set { withStateLock { routingState.volumeSessionActive = newValue } }
    }
```

Replace the whole `if key.isVolume && volumeKeysHijacked { ... }` block and the comment line after it with:

```swift
        if key.isVolume || key == .mute {
            let state = withStateLock { routingState }
            let action = VolumeKeyAction.resolve(
                key: key,
                commandHeld: event.flags.contains(.maskCommand),
                hijacked: state.volumeKeysHijacked,
                targetHasVolume: state.targetHasVolume,
                sessionActive: state.volumeSessionActive)
            switch action {
            case .passThrough:
                return Unmanaged.passUnretained(event)
            case .passThroughWithoutCommand:
                // Command-volume is an escape hatch to the normal system volume.
                // Remove Command before passing the event through so macOS receives
                // an ordinary volume key rather than a modified shortcut.
                event.flags = event.flags.subtracting(.maskCommand)
                return Unmanaged.passUnretained(event)
            case .handle:
                // Volume: key-down AND repeats, so holding the key ramps. Mute:
                // a fresh key-down only — a held key must not flap the toggle.
                // Both down and up are swallowed either way.
                if decoded.isDown && (key.isVolume || !decoded.isRepeat) {
                    DispatchQueue.main.async { [weak self] in self?.handler(key) }
                }
                return nil
            }
        }

        // Everything else (ff/rewind) passes through.
        return Unmanaged.passUnretained(event)
```

Update the `handler` doc comment on `init` to read: "`handler` for transport keys the tap swallowed and routed, and for volume keys and ⌘+Mute that `VolumeKeyAction` says Beamhook handles (volume keys including repeats)".

In `Sources/BeamhookKit/MediaKey.swift`, change the `isVolume` doc comment to:

```swift
    /// Hardware volume up/down. Mute is separate: plain mute always belongs to
    /// the system, ⌘+Mute toggles the volume source (see `VolumeKeyAction`).
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `APP_SOURCES="Sources/Beamhook/System/MediaKeyTap.swift" $H/run-kit-tests.sh Tests/BeamhookTests/MediaKeyTapTests.swift`
Expected: `12 tests run`, `ALL PASSED`.

Run: `$H/typecheck-app.sh`
Expected: `APP TYPECHECK OK`.

- [ ] **Step 5: Commit**

```bash
git add Sources/Beamhook/System/MediaKeyTap.swift Sources/BeamhookKit/MediaKey.swift Tests/BeamhookTests/MediaKeyTapTests.swift
git commit -m "Route volume and Command-Mute through VolumeKeyAction

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: `SourcePickerKeyTap`

**Depends on:** Task 1 (`SourcePickerKey`).

**Files:**
- Create: `Sources/Beamhook/System/SourcePickerKeyTap.swift`
- Create: `Tests/BeamhookTests/SourcePickerKeyTapTests.swift`

**Interfaces:**
- Consumes: `SourcePickerKey.match(keyCode:command:shift:option:control:)`.
- Produces:
  - `final class SourcePickerKeyTap: @unchecked Sendable`
  - `init(handler: @escaping (SourcePickerKey) -> Void)` — handler invoked on the main queue, key-downs only (including auto-repeat).
  - `func arm()`, `func disarm()` — called on the main thread; idempotent.
  - `func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>?` — internal for tests.

- [ ] **Step 1: Write the failing tests**

`Tests/BeamhookTests/SourcePickerKeyTapTests.swift`:

```swift
import XCTest
@testable import Beamhook
import BeamhookKit

final class SourcePickerKeyTapTests: XCTestCase {
    private func keyEvent(_ keyCode: CGKeyCode, down: Bool = true,
                          flags: CGEventFlags = .maskCommand) -> CGEvent {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: down)!
        event.flags = flags
        return event
    }

    private func drainMainQueue() {
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 1)
    }

    func testCommandArrowsAreSwallowedAndReported() {
        var keys: [SourcePickerKey] = []
        let tap = SourcePickerKeyTap { keys.append($0) }

        XCTAssertNil(tap.handle(type: .keyDown, event: keyEvent(126)))
        XCTAssertNil(tap.handle(type: .keyDown, event: keyEvent(125)))

        drainMainQueue()
        XCTAssertEqual(keys, [.previous, .next])
    }

    func testFnAndNumericPadFlagsAreIgnored() {
        var keys: [SourcePickerKey] = []
        let tap = SourcePickerKeyTap { keys.append($0) }

        let flags: CGEventFlags = [.maskCommand, .maskSecondaryFn, .maskNumericPad]
        XCTAssertNil(tap.handle(type: .keyDown, event: keyEvent(116, flags: flags)))

        drainMainQueue()
        XCTAssertEqual(keys, [.previous])
    }

    func testKeyUpIsSwallowedButNotReported() {
        var keys: [SourcePickerKey] = []
        let tap = SourcePickerKeyTap { keys.append($0) }

        XCTAssertNil(tap.handle(type: .keyUp, event: keyEvent(126, down: false)))

        drainMainQueue()
        XCTAssertTrue(keys.isEmpty)
    }

    func testOtherKeystrokesPassUntouched() {
        var keys: [SourcePickerKey] = []
        let tap = SourcePickerKeyTap { keys.append($0) }

        XCTAssertNotNil(tap.handle(type: .keyDown, event: keyEvent(126, flags: [])))
        XCTAssertNotNil(tap.handle(type: .keyDown, event: keyEvent(126, flags: [.maskCommand, .maskShift])))
        XCTAssertNotNil(tap.handle(type: .keyDown, event: keyEvent(0)))   // ⌘A

        drainMainQueue()
        XCTAssertTrue(keys.isEmpty)
    }

    func testDisarmWithoutArmIsHarmless() {
        let tap = SourcePickerKeyTap { _ in }
        tap.disarm()
        tap.disarm()
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `APP_SOURCES="Sources/Beamhook/System/SourcePickerKeyTap.swift" $H/run-kit-tests.sh Tests/BeamhookTests/SourcePickerKeyTapTests.swift`
Expected: failure — the source file does not exist yet (`sed: ...: No such file or directory` or `cannot find 'SourcePickerKeyTap' in scope`).

- [ ] **Step 3: Implement**

`Sources/Beamhook/System/SourcePickerKeyTap.swift`:

```swift
import Cocoa
import CoreGraphics
import os
import BeamhookKit

/// A keyboard tap that exists only while Beamhook's volume HUD is on screen. It
/// swallows ⌘↑/⌘↓ (and the ⌘PgUp/⌘PgDn aliases) for the volume-source picker
/// and hands every other keystroke back untouched. Between `disarm()` and the
/// next `arm()` there is no keyboard tap at all, so Beamhook never sees ordinary
/// typing.
///
/// Threading: `arm()`/`disarm()` are called on the main thread. The tap lives on
/// a dedicated thread's run loop — an installed keyboard tap delays every
/// keystroke on the system until its callback returns, so it must never wait on
/// a busy main thread. The tap objects are touched only on that thread.
final class SourcePickerKeyTap: @unchecked Sendable {
    typealias Handler = (SourcePickerKey) -> Void

    private static let log = Logger(subsystem: "com.github.ppixu.beamhook", category: "SourcePicker")

    private let handler: Handler
    private let lock = NSLock()
    private var runLoop: CFRunLoop?          // guarded by `lock`
    private var thread: Thread?              // main thread only
    private var eventTap: CFMachPort?        // tap thread only
    private var runLoopSource: CFRunLoopSource?   // tap thread only

    /// `handler` runs on the main queue, for key-downs (auto-repeat included, so
    /// holding ⌘↓ walks the list).
    init(handler: @escaping Handler) {
        self.handler = handler
    }

    func arm() {
        startThreadIfNeeded()
        performOnTapThread { [weak self] in self?.installTap() }
    }

    func disarm() {
        performOnTapThread { [weak self] in self?.removeTap() }
    }

    /// Internal rather than private so the unit tests can drive it with
    /// synthetic events; only the tap callback calls it in production.
    func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let flags = event.flags
        guard let key = SourcePickerKey.match(
            keyCode: Int(event.getIntegerValueField(.keyboardEventKeycode)),
            command: flags.contains(.maskCommand),
            shift: flags.contains(.maskShift),
            option: flags.contains(.maskAlternate),
            control: flags.contains(.maskControl))
        else {
            return Unmanaged.passUnretained(event)
        }
        if type == .keyDown {
            DispatchQueue.main.async { [weak self] in self?.handler(key) }
        }
        // Swallow the key-up too, so the frontmost app never sees half a chord.
        return nil
    }

    private func startThreadIfNeeded() {
        guard thread == nil else { return }
        let started = DispatchSemaphore(value: 0)
        let t = Thread { [weak self] in
            guard let self else { started.signal(); return }
            self.lock.withLock { self.runLoop = CFRunLoopGetCurrent() }
            // A run loop with no sources returns at once; a port keeps it alive
            // between arms.
            RunLoop.current.add(NSMachPort(), forMode: .default)
            started.signal()
            CFRunLoopRun()
        }
        t.name = "com.beamhook.source-picker-tap"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
        started.wait()
    }

    private func installTap() {
        guard eventTap == nil else { return }
        let mask = (CGEventMask(1) << CGEventMask(CGEventType.keyDown.rawValue))
            | (CGEventMask(1) << CGEventMask(CGEventType.keyUp.rawValue))
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            let me = Unmanaged<SourcePickerKeyTap>.fromOpaque(userInfo!).takeUnretainedValue()
            return me.handle(type: type, event: event)
        }
        // `self` is passed unretained; AppState holds this object for the app's
        // whole lifetime, so it always outlives the installed tap.
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                          place: .headInsertEventTap,
                                          options: .defaultTap,
                                          eventsOfInterest: mask,
                                          callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque())
        else {
            Self.log.error("could not create the source-picker keyboard tap")
            return
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTap = tap
        runLoopSource = source
    }

    private func removeTap() {
        guard let tap = eventTap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        }
        CFMachPortInvalidate(tap)
        eventTap = nil
        runLoopSource = nil
    }

    private func performOnTapThread(_ block: @escaping () -> Void) {
        guard let rl = lock.withLock({ runLoop }) else { return }
        CFRunLoopPerformBlock(rl, CFRunLoopMode.commonModes.rawValue, block)
        CFRunLoopWakeUp(rl)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `APP_SOURCES="Sources/Beamhook/System/SourcePickerKeyTap.swift" $H/run-kit-tests.sh Tests/BeamhookTests/SourcePickerKeyTapTests.swift`
Expected: `5 tests run`, `ALL PASSED`.

Run: `$H/typecheck-app.sh`
Expected: `APP TYPECHECK OK`.

- [ ] **Step 5: Commit**

```bash
git add Sources/Beamhook/System/SourcePickerKeyTap.swift Tests/BeamhookTests/SourcePickerKeyTapTests.swift
git commit -m "Add a keyboard tap that exists only while the volume HUD is up

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: `HookHUD` — hint line, source list, visibility callback

**Files:**
- Modify: `Sources/Beamhook/UI/HookHUD.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces on `HookHUD`:
  - `struct SourceRow: Equatable { let name: String; let percent: Int? }` (nested in `HookHUD`; `percent == 0` renders "muted", `nil` renders an empty track)
  - `func showVolume(appName: String, percent: Int, systemVolumeHint: Bool)` — replaces the old two-argument `showVolume`. `systemVolumeHint` shows today's "⌘ + 🔊 for system volume" line.
  - `func showVolumeSources(_ rows: [SourceRow], selectedIndex: Int)`
  - `var onVolumeVisibilityChange: ((Bool) -> Void)?` — called with `true` when a `.volume` or `.volumeSources` presentation is shown while none was, and `false` when it hides or is replaced by another presentation.

No unit tests (AppKit view code); verification is the typecheck plus Task 7's manual check.

- [ ] **Step 1: Extend `Presentation`**

Change the `.volume` case and add `.volumeSources`:

```swift
        /// `systemVolumeHint`: the volume keys are hooked, so ⌘ reaches the
        /// system volume — say so. Off when ⌘+Volume brought this up.
        case volume(appName: String, percent: Int, systemVolumeHint: Bool)
        /// The volume-source picker: one row per source, one selected.
        case volumeSources(rows: [SourceRow], selectedIndex: Int)
```

Update `appName`:

```swift
        var appName: String {
            switch self {
            case .hooked(let appName, _), .volume(let appName, _, _),
                 .launching(let appName), .playback(let appName, _),
                 .passthrough(let appName, _): appName
            case .volumeSources(let rows, let selectedIndex):
                rows.indices.contains(selectedIndex) ? rows[selectedIndex].name : "volume sources"
            }
        }

        var isVolume: Bool {
            switch self {
            case .volume, .volumeSources: true
            default: false
            }
        }
```

In `hideDelay`, add `case .volumeSources: 2.5` (keep `.volume: 1.5`).

Add the row type inside `HookHUD`, above `Presentation`:

```swift
    /// One row of the volume-source picker. `percent` 0 reads as muted; nil
    /// means the volume hasn't been read yet.
    struct SourceRow: Equatable {
        let name: String
        let percent: Int?
    }
```

- [ ] **Step 2: Public entry points and the callback**

Replace `showVolume(appName:percent:)` with:

```swift
    /// Show an app-specific volume HUD after a hooked volume-key command succeeds.
    func showVolume(appName: String, percent: Int, systemVolumeHint: Bool) {
        show(.volume(appName: appName, percent: min(100, max(0, percent)),
                     systemVolumeHint: systemVolumeHint))
    }

    /// Show the volume-source picker with `selectedIndex` highlighted.
    func showVolumeSources(_ rows: [SourceRow], selectedIndex: Int) {
        show(.volumeSources(rows: rows, selectedIndex: selectedIndex))
    }
```

Add next to `onPresent`:

```swift
    /// Told when a volume presentation appears (true) and when it goes away —
    /// hidden, or replaced by another presentation (false). AppState arms the
    /// ⌘↑/⌘↓ keyboard tap only in between.
    var onVolumeVisibilityChange: ((Bool) -> Void)?
    private var volumeVisible = false

    private func setVolumeVisible(_ visible: Bool) {
        guard visible != volumeVisible else { return }
        volumeVisible = visible
        onVolumeVisibilityChange?(visible)
    }
```

- [ ] **Step 3: New views**

Add stored properties next to `hintRow`:

```swift
    /// "⌘ ↑↓ switch · ⌘ <speaker.slash> mute", under every volume presentation.
    private var pickerHint: NSView?
    /// The picker's rows; rebuilt on every `.volumeSources` show.
    private var sourceList: NSStackView?
```

In `ensurePanel()`, after `volumeStack` is built, create:

```swift
        let sources = NSStackView()
        sources.orientation = .vertical
        sources.alignment = .leading
        sources.spacing = 4
        sources.isHidden = true

        let picker = Self.makePickerHint()
        picker.isHidden = true
```

Change the main stack to include them, in this order:

```swift
        let stack = NSStackView(views: [header, volumeStack, sources, picker])
```

and store them at the end of `ensurePanel()`:

```swift
        self.pickerHint = picker
        self.sourceList = sources
```

Add the hint builder next to `makeSystemVolumeHint()`, using its `caption` style:

```swift
    /// "⌘ ↑↓ switch · ⌘ <speaker.slash.fill> mute" — the picker's keys, built
    /// as a row so the mute mark is the real SF Symbol, like the system hint.
    private static func makePickerHint() -> NSStackView {
        func caption(_ string: String) -> NSTextField {
            let field = NSTextField(labelWithString: string)
            field.font = .systemFont(ofSize: 11, weight: .regular)
            field.textColor = .secondaryLabelColor
            field.setAccessibilityElement(false)
            return field
        }

        let muted = NSImageView()
        muted.image = NSImage(systemSymbolName: "speaker.slash.fill",
                              accessibilityDescription: "Mute")
        muted.symbolConfiguration = .init(pointSize: 11, weight: .regular)
        muted.contentTintColor = .secondaryLabelColor
        muted.imageScaling = .scaleNone
        muted.setContentHuggingPriority(.required, for: .horizontal)
        muted.setAccessibilityElement(false)

        let row = NSStackView(views: [caption("⌘ ↑↓ switch · ⌘"), muted, caption("mute")])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 3
        row.setAccessibilityElement(true)
        row.setAccessibilityRole(.staticText)
        row.setAccessibilityLabel("Command Up or Down to switch source, Command Mute to mute")
        return row
    }

    /// One picker row: marker, name, then a mini bar or "muted".
    private static func makeSourceRow(_ row: SourceRow, selected: Bool) -> NSView {
        let marker = NSTextField(labelWithString: selected ? "▸" : "")
        marker.font = .systemFont(ofSize: 13, weight: .semibold)
        marker.textColor = .labelColor
        marker.setAccessibilityElement(false)

        let name = NSTextField(labelWithString: row.name)
        name.font = .systemFont(ofSize: 13, weight: selected ? .semibold : .regular)
        name.textColor = .labelColor
        name.lineBreakMode = .byTruncatingTail
        name.setAccessibilityElement(false)

        let level: NSView
        if row.percent == 0 {
            let icon = NSImageView()
            icon.image = NSImage(systemSymbolName: "speaker.slash.fill", accessibilityDescription: nil)
            icon.symbolConfiguration = .init(pointSize: 11, weight: .regular)
            icon.contentTintColor = .secondaryLabelColor
            let text = NSTextField(labelWithString: "muted")
            text.font = .systemFont(ofSize: 11, weight: .regular)
            text.textColor = .secondaryLabelColor
            let mutedStack = NSStackView(views: [icon, text])
            mutedStack.orientation = .horizontal
            mutedStack.spacing = 4
            level = mutedStack
        } else {
            let bar = VolumeBarView()
            bar.percent = row.percent ?? 0
            bar.setAccessibilityElement(false)
            level = bar
        }

        let line = NSStackView(views: [marker, name, level])
        line.orientation = .horizontal
        line.alignment = .centerY
        line.spacing = 6
        line.edgeInsets = NSEdgeInsets(top: 3, left: 4, bottom: 3, right: 8)
        line.wantsLayer = true
        line.layer?.cornerRadius = 6
        if selected {
            line.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.12).cgColor
        }
        line.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            marker.widthAnchor.constraint(equalToConstant: 10),
            name.widthAnchor.constraint(equalToConstant: 132),
            level.widthAnchor.constraint(equalToConstant: 104),
            level.heightAnchor.constraint(equalToConstant: row.percent == 0 ? 14 : 5),
        ])

        let state = row.percent.map { $0 == 0 ? "muted" : "\($0) percent" } ?? "volume unknown"
        line.setAccessibilityElement(true)
        line.setAccessibilityRole(.staticText)
        line.setAccessibilityLabel("\(row.name), \(state)\(selected ? ", selected" : "")")
        return line
    }
```

Note: `.labelColor.cgColor` resolves against the current appearance at call time; `present` runs after `ensurePanel()` applied the HUD's contrasting appearance, so build rows inside `panel.appearance?.performAsCurrentDrawingAppearance { ... }` (see Step 4).

- [ ] **Step 4: Render the presentations**

In `present(_:gen:attempt:)`, at the top of the rendering block (next to `noticeLabel?.isHidden = true`) add the defaults so each case stays a checklist of what it shows:

```swift
        pickerHint?.isHidden = true
        sourceList?.isHidden = true
```

Header visibility: every existing case leaves the header visible; `.volumeSources` hides it. Add `header` to the stored properties as `private var header: NSView?`, set `self.header = header` in `ensurePanel()`, and set `header?.isHidden = false` alongside the two defaults above.

Change the `.volume` case:

```swift
        case .volume(let appName, let percent, let systemVolumeHint):
            label?.stringValue = appName
            hintRow?.isHidden = !systemVolumeHint
            hookIcon?.isHidden = true
            transportIcon?.isHidden = true
            volumeRow?.isHidden = false
            volumeBar?.percent = percent
            pickerHint?.isHidden = false
```

Add the new case:

```swift
        case .volumeSources(let rows, let selectedIndex):
            header?.isHidden = true
            volumeRow?.isHidden = true
            pickerHint?.isHidden = false
            if let sourceList {
                sourceList.arrangedSubviews.forEach { $0.removeFromSuperview() }
                panel.appearance?.performAsCurrentDrawingAppearance {
                    for (index, row) in rows.enumerated() {
                        sourceList.addArrangedSubview(
                            Self.makeSourceRow(row, selected: index == selectedIndex))
                    }
                }
                sourceList.isHidden = false
            }
```

After `if case .hooked = presentation { onPresent?() }` add:

```swift
        setVolumeVisible(presentation.isVolume)
```

In `dismiss(gen:)`, after the `guard`, add:

```swift
        setVolumeVisible(false)
```

- [ ] **Step 5: Keep the existing caller compiling**

`AppState.drainVolumeSteps` calls the old `showVolume(appName:percent:)`. Update that one call (Task 7 rewrites the function; this keeps the tree compiling between tasks):

```swift
                HookHUD.shared.showVolume(appName: appName, percent: result.volume,
                                          systemVolumeHint: tap.volumeKeysHijacked)
```

- [ ] **Step 6: Verify**

Run: `$H/typecheck-app.sh`
Expected: `APP TYPECHECK OK`.

Run: `grep -n "showVolume(appName" Sources/Beamhook/*.swift Sources/Beamhook/UI/*.swift`
Expected: every call passes `systemVolumeHint:`.

- [ ] **Step 7: Commit**

```bash
git add Sources/Beamhook/UI/HookHUD.swift Sources/Beamhook/AppState.swift
git commit -m "Give the volume HUD a source list and a picker hint

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: `AppState` — the volume session

**Depends on:** Tasks 1–6.

**Files:**
- Modify: `Sources/Beamhook/AppState.swift`

**Interfaces:**
- Consumes: `VolumeSource`, `VolumeSourceEntry`, `VolumeSourceList`, `MuteMemory`, `VolumeChange`, `TargetManager.updateVolume(_:)`, `TargetManager.updateVolume(ofBundleID:_:)`, `TargetManager.volumeStep`, `MediaKeyTap.targetHasVolume`, `MediaKeyTap.volumeSessionActive`, `SourcePickerKeyTap(handler:)`, `arm()`, `disarm()`, `SourcePickerKey`, `HookHUD.SourceRow`, `HookHUD.showVolume(appName:percent:systemVolumeHint:)`, `HookHUD.showVolumeSources(_:selectedIndex:)`, `HookHUD.onVolumeVisibilityChange`, existing `AudioProcessMonitor` (macOS 14.2+), `refreshActiveBrowserMedia(bundleIDs:)`, `setBrowserVolume(_:for:)`, `volume(for:)`, `volumeScriptable(bundleID:)`.
- Produces: no new public API; behavior only.

No unit tests (AppState isn't unit-tested in this repo; its logic is now in the Kit types). Verification: typecheck + full harness run + the manual checklist in Step 8.

- [ ] **Step 1: State**

Add next to `pendingVolumeSteps` / `volumeDrainInFlight`:

```swift
    /// Pre-mute volumes, so ⌘+Mute can undo itself. Outlives sessions.
    private var muteMemory = MuteMemory()
    /// Non-nil while the source list is on screen — the spec's "volume session".
    /// While set, every volume key and ⌘+Mute follow its selection.
    private var volumeSession: VolumeSourceList? {
        didSet { tap.volumeSessionActive = volumeSession != nil }
    }
    /// The session's background refresh (volumes, browser tabs).
    private var volumeSessionRefresh: Task<Void, Never>?
    /// Exists for the app's lifetime; only *installed* while a volume HUD is up.
    private lazy var sourcePickerTap = SourcePickerKeyTap { [weak self] key in
        MainActor.assumeIsolated { self?.handleSourcePickerKey(key) }
    }
```

- [ ] **Step 2: Route mute from the tap**

In `handleKey(_:)`, add a case before `default:`:

```swift
        case .mute:       toggleMute()
```

- [ ] **Step 3: Keep `targetHasVolume` current**

Replace `updateVolumeHijack()` with:

```swift
    /// The volume keys are hijacked for the target only when it exposes a scriptable
    /// volume AND the user has explicitly enabled it for that app.
    private func updateVolumeHijack() {
        tap.volumeKeysHijacked = VolumeKeyRouting.shouldHijack(
            targetBundleID: targetManager.targetBundleID,
            targetSupportsVolume: targetManager.targetSupportsVolume,
            preferences: volumeKeyOverride
        )
        updateTargetHasVolume()
    }

    /// Whether ⌘+Volume / ⌘+Mute have something to act on. A browser target only
    /// does once a scan found a tab with a volume; until then the keys stay with
    /// macOS rather than being swallowed for nothing.
    private func updateTargetHasVolume() {
        let browserReady = !selectedTargetIsBrowser || selectedBrowserMediaCandidate?.volume != nil
        tap.targetHasVolume = targetManager.targetSupportsVolume && browserReady
    }
```

Add `updateTargetHasVolume()` to the existing `didSet` of both `browserMediaCandidates` and `selectedBrowserMediaID` (after `updateMenuBarGlyph()`).

- [ ] **Step 4: One read-modify-write path for every source**

Replace `drainVolumeSteps()` with:

```swift
    private func drainVolumeSteps() async {
        defer { volumeDrainInFlight = false }
        while pendingVolumeSteps != 0 {
            let steps = pendingVolumeSteps
            pendingVolumeSteps = 0
            let delta = steps * targetManager.volumeStep
            await changeVolume(of: currentVolumeSource) { $0 + delta }
        }
    }

    /// The session's selected source, otherwise the hooked target.
    private var currentVolumeSource: VolumeSource {
        volumeSession?.selected?.source ?? .hookedTarget
    }

    /// Read-modify-write one source's volume (AppleScript off main), update the
    /// caches the menu and HUD read, then show the HUD. Returns the change, or nil
    /// when nothing was changed (source gone, not ready, no volume).
    @discardableResult
    private func changeVolume(of source: VolumeSource,
                              _ transform: @escaping (Int) -> Int) async -> VolumeChange? {
        let change: VolumeChange?
        switch source {
        case .hookedTarget:
            change = await targetManager.updateVolume(transform)
            if let change {
                volumeByBundle[change.bundleID] = change.volume
                if selectedTargetIsBrowser, let id = selectedBrowserMediaID,
                   let index = browserMediaCandidates.firstIndex(where: { $0.id == id }) {
                    browserMediaCandidates[index].volume = change.volume
                }
            }
        case .app(let bundleID):
            change = await targetManager.updateVolume(ofBundleID: bundleID, transform)
            if let change { volumeByBundle[bundleID] = change.volume }
        case .browserTab(let id):
            if let candidate = browserCandidate(id: id), let current = candidate.volume {
                let next = min(100, max(0, transform(current)))
                setBrowserVolume(next, for: candidate)   // updates both caches, sends off main
                change = VolumeChange(bundleID: candidate.browser.bundleID, previous: current, volume: next)
            } else {
                change = nil
            }
        }
        guard let change else { return nil }
        if volumeSession != nil {
            showVolumeSessionHUD()
        } else {
            let appName = availableApps.first { $0.bundleID == change.bundleID }?.displayName
                ?? change.bundleID
            HookHUD.shared.showVolume(appName: appName, percent: change.volume,
                                      systemVolumeHint: tap.volumeKeysHijacked)
        }
        return change
    }

    private func browserCandidate(id: String) -> BrowserMediaCandidate? {
        activeBrowserMediaCandidates.first { $0.id == id }
            ?? browserMediaCandidates.first { $0.id == id }
    }
```

- [ ] **Step 5: Mute**

Add:

```swift
    /// ⌘+Mute: silence the current volume source, or put back what muting took.
    private func toggleMute() {
        let source = currentVolumeSource
        let key = muteMemoryKey(for: source)
        let restore = muteMemory.restoreVolume(for: key)
        Task {
            guard let change = await changeVolume(of: source, {
                MuteMemory.toggled(from: $0, restore: restore)
            }) else { return }
            muteMemory.record(sourceID: key, previous: change.previous, new: change.volume)
        }
    }

    /// Mute memory follows the thing actually silenced, not the "hooked target"
    /// role — re-hooking another app must not make it inherit a restore value.
    private func muteMemoryKey(for source: VolumeSource) -> String {
        guard source == .hookedTarget else { return source.id }
        if selectedTargetIsBrowser, let id = selectedBrowserMediaID {
            return VolumeSource.browserTab(id: id).id
        }
        return VolumeSource.app(bundleID: targetManager.targetBundleID ?? "").id
    }
```

- [ ] **Step 6: The session**

Add:

```swift
    // MARK: - Volume source picker

    private func volumeHUDVisibilityChanged(_ visible: Bool) {
        if visible {
            sourcePickerTap.arm()
        } else {
            sourcePickerTap.disarm()
            volumeSessionRefresh?.cancel()
            volumeSessionRefresh = nil
            volumeSession = nil
        }
    }

    /// ⌘↑/⌘↓ while a volume HUD is up. The first press opens the session (the
    /// HUD grows into the list) and moves the selection one row.
    private func handleSourcePickerKey(_ key: SourcePickerKey) {
        if volumeSession == nil {
            let audible = audibleBundleIDs()
            volumeSession = VolumeSourceList(target: hookedVolumeEntry(),
                                             apps: playingVolumeApps(audible: audible),
                                             tabs: browserVolumeTabs())
            startVolumeSessionRefresh(audible: audible)
        }
        switch key {
        case .previous: volumeSession?.selectPrevious()
        case .next: volumeSession?.selectNext()
        }
        showVolumeSessionHUD()
    }

    private func showVolumeSessionHUD() {
        guard let session = volumeSession else { return }
        let rows = session.entries.map {
            HookHUD.SourceRow(name: $0.name, percent: currentVolume(of: $0.source))
        }
        HookHUD.shared.showVolumeSources(rows, selectedIndex: session.selectedIndex)
    }

    /// Cached volume for a row; the session refresh fills these in.
    private func currentVolume(of source: VolumeSource) -> Int? {
        switch source {
        case .hookedTarget:
            if selectedTargetIsBrowser, let volume = selectedBrowserMediaCandidate?.volume {
                return volume
            }
            return targetManager.targetBundleID.flatMap { volumeByBundle[$0] }
        case .app(let bundleID):
            return volumeByBundle[bundleID]
        case .browserTab(let id):
            return browserCandidate(id: id)?.volume
        }
    }

    private func hookedVolumeEntry() -> VolumeSourceEntry? {
        guard tap.targetHasVolume, let def = currentTargetDefinition() else { return nil }
        let name = selectedTargetIsBrowser
            ? (selectedBrowserMediaCandidate?.label ?? def.displayName)
            : def.displayName
        return VolumeSourceEntry(source: .hookedTarget, name: name)
    }

    /// Bundle ids with a live audio output stream. Before macOS 14.2 there's no
    /// per-process audio API, so every running supported browser stands in (its
    /// tabs are still scanned) and no other apps are offered.
    private func audibleBundleIDs() -> Set<String> {
        if #available(macOS 14.2, *) {
            let monitor = AudioProcessMonitor()
            monitor.refresh()
            return Set(monitor.playingApps.map(\.bundleID))
        }
        return Set(BrowserKind.allCases.map(\.bundleID).filter { isRunning(bundleID: $0) })
    }

    /// Other playing apps Beamhook can script the volume of, by name. The hooked
    /// target is row 1 already, and browsers contribute tabs instead.
    private func playingVolumeApps(audible: Set<String>) -> [VolumeSourceEntry] {
        let targetBundleID = targetManager.targetBundleID
        return audible
            .filter { $0 != targetBundleID
                && BrowserKind.browser(bundleID: $0) == nil
                && volumeScriptable(bundleID: $0) }
            .map { bundleID in
                VolumeSourceEntry(source: .app(bundleID: bundleID),
                                  name: availableApps.first { $0.bundleID == bundleID }?.displayName
                                      ?? bundleID)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Tabs with a volume from the last active-browser scan, minus the hooked tab.
    private func browserVolumeTabs() -> [VolumeSourceEntry] {
        let hookedTabID = selectedTargetIsBrowser ? selectedBrowserMediaID : nil
        return activeBrowserMediaCandidates
            .filter { $0.volume != nil && $0.id != hookedTabID }
            .map { VolumeSourceEntry(source: .browserTab(id: $0.id),
                                     name: "\($0.label) · \($0.browser.applicationName)") }
    }

    /// Read every row's volume and scan browser tabs, off main, then redraw. The
    /// list shows immediately from caches; this only fills it in.
    private func startVolumeSessionRefresh(audible: Set<String>) {
        volumeSessionRefresh?.cancel()
        volumeSessionRefresh = Task { [weak self] in
            guard let self else { return }
            for entry in self.volumeSession?.entries ?? [] {
                guard !Task.isCancelled else { return }
                let bundleID: String?
                switch entry.source {
                case .hookedTarget:
                    bundleID = self.selectedTargetIsBrowser ? nil : self.targetManager.targetBundleID
                case .app(let id):
                    bundleID = id
                case .browserTab:
                    bundleID = nil
                }
                if let bundleID, let volume = await self.volume(for: bundleID) {
                    self.volumeByBundle[bundleID] = volume
                }
            }
            guard !Task.isCancelled, self.volumeSession != nil else { return }
            self.showVolumeSessionHUD()

            await self.refreshActiveBrowserMedia(bundleIDs: audible)
            guard !Task.isCancelled, self.volumeSession != nil else { return }
            self.volumeSession?.replace(target: self.hookedVolumeEntry(),
                                        apps: self.playingVolumeApps(audible: audible),
                                        tabs: self.browserVolumeTabs())
            self.showVolumeSessionHUD()
        }
    }
```

- [ ] **Step 7: Wire the HUD callback**

In `activateInput()`, after `updateVolumeHijack()`:

```swift
        HookHUD.shared.onVolumeVisibilityChange = { [weak self] visible in
            self?.volumeHUDVisibilityChanged(visible)
        }
```

Run: `$H/typecheck-app.sh`
Expected: `APP TYPECHECK OK`.

Run the full harness to confirm nothing regressed:

```bash
ls Tests/BeamhookKitTests/*Tests.swift | xargs $H/run-kit-tests.sh
APP_SOURCES="Sources/Beamhook/System/MediaKeyTap.swift Sources/Beamhook/System/SourcePickerKeyTap.swift" $H/run-kit-tests.sh Tests/BeamhookTests/MediaKeyTapTests.swift Tests/BeamhookTests/SourcePickerKeyTapTests.swift
```

Expected: both end with `ALL PASSED`.

Run: `xcodegen generate`
Expected: `Created project at <repo>/Beamhook.xcodeproj` (picks up the new files; the project is not committed).

- [ ] **Step 8: Manual checklist (for the user on a Mac with the built app — record in the final report, do not block on it)**

1. Hook Spotify, volume hook ON. Vol ↑ → compact HUD with the new hint line at the bottom.
2. Within the HUD, ⌘↓ → HUD becomes the list, row 2 selected. Vol ↑ (holding ⌘ or not) changes that row's bar, not Spotify, not system volume.
3. Wait ~2.5 s → HUD fades. Vol ↑ → Spotify again. ⌘↑ in Finder now goes to the parent folder (tap disarmed).
4. ⌘+Mute → Spotify bar to 0 / row "muted"; again → restored.
5. Volume hook OFF: plain Vol → system HUD; ⌘+Vol → Beamhook HUD for Spotify.
6. Chrome playing YouTube with "Allow JavaScript from Apple Events": the tab row appears a moment after the list opens.
7. Light and dark mode: rows readable, selected row highlighted.

- [ ] **Step 9: Commit**

```bash
git add Sources/Beamhook/AppState.swift
git commit -m "Pick the volume source from the HUD and mute it with Command-Mute

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 8: Docs

**Depends on:** Task 7.

**Files:**
- Modify: `README.md` (the feature list, ~lines 41–46)
- Modify: `CHANGELOG.md` (new `## [Unreleased]` section above `## [1.1.10]`)

Do **not** edit `docs/index.html` — it holds the user's uncommitted edits; the website copy is left for the user.

- [ ] **Step 1: README**

Replace the line `- Hold Command while pressing a volume key to adjust the Mac's system volume instead.` with:

```markdown
- Hold Command to flip what the volume keys do: with volume keys routed to the
  app, ⌘ + Volume adjusts the Mac's system volume; without, ⌘ + Volume adjusts
  the app.
- While the volume overlay is showing, ⌘↑ / ⌘↓ switches between the apps and
  browser tabs that are playing, and the volume keys then adjust the one you
  picked. It goes back to the hooked app when the overlay fades.
- ⌘ + Mute mutes or unmutes just that app or tab; plain Mute is still the
  system's.
```

- [ ] **Step 2: CHANGELOG**

Insert above `## [1.1.10] — 2026-08-09`:

```markdown
## [Unreleased]

### Added

- **Pick whose volume the keys control, right from the overlay.** While the
  volume overlay is up, ⌘↑ / ⌘↓ grows it into a list of the apps and browser
  tabs that are playing, each with its own level, and moves the selection. The
  volume keys then adjust the picked source until the overlay fades, so
  turning down a YouTube tab no longer means opening the menu. ⌘PgUp / ⌘PgDn
  work too. Beamhook only listens for these keys while the overlay is on
  screen.
- **⌘ + Mute mutes one app or tab.** It silences the current source — the
  picked one, or the hooked app — and pressing it again restores the previous
  level. Plain Mute still mutes the whole Mac.
- **⌘ + Volume reaches the hooked app when the volume keys aren't routed to
  it.** ⌘ now flips the volume keys either way.
```

- [ ] **Step 3: Commit**

```bash
git add README.md CHANGELOG.md
git commit -m "Document the volume source picker and Command-Mute

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

- [ ] **Step 4: Verify the docs match the code**

Check that every key in README/CHANGELOG matches `SourcePickerKey` (126/125/116/121) and `VolumeKeyAction`, and that the hint text in `HookHUD.makePickerHint` reads `⌘ ↑↓ switch · ⌘ … mute`.
