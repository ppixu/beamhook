# Launch the hooked app on play/pause — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When the hooked target app isn't running, pressing play/pause launches it and starts playback — with the toggle for it living in a new two-tab Settings window.

**Architecture:** A new `@MainActor` kit type, `TargetLauncher`, owns the sequence: launch through an injected `AppLaunching` seam (`NSWorkspace` in the app target), poll `isReady` through an injected `Sleeping` seam, then send `.playPause` on the existing command-lane `ScriptRunner` — but only after checking the app didn't already start playing on its own. `AppState.handleKey` calls it as a fallback when `TargetManager.route` reports it delivered nothing. Separately, the three controls in `SettingsSection` move out of the 220pt popover into a real `SettingsWindow` (General + Apps tabs), which the new toggle joins.

**Tech Stack:** Swift 5, SwiftUI + AppKit, macOS 14+, XCTest, XcodeGen.

**Spec:** `docs/superpowers/specs/2026-07-30-launch-target-on-play-design.md`

## Global Constraints

- **Never call AppleScript on the main thread.** Every `NSAppleScript` call goes through a `ScriptRunning` off-main serial queue. Blocking the main thread is what caused the July 2026 system freeze.
- **Never launch an app by sending it an Apple event** (`tell application "X" to playpause` launches implicitly). The send blocks until launch completes and would occupy the serial command lane.
- **Deployment target macOS 14.0**, `SWIFT_VERSION 5.0`.
- **Regenerate the Xcode project after adding or deleting any file:** `xcodegen generate`. `Beamhook.xcodeproj` is not committed.
- **`MenuBarExtra(.window)` popovers dismiss when a `.sheet` takes focus** — settings use a real `NSWindow`, never a sheet.
- **Kit code (`Sources/BeamhookKit/`) must not import AppKit** or make system calls; system access enters through protocol seams.
- Test commands:
  - Kit: `xcodebuild test -project Beamhook.xcodeproj -scheme BeamhookKit -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`
  - App: `xcodebuild test -project Beamhook.xcodeproj -scheme Beamhook -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`
- Build + launch for manual checks: `./run.sh` (signs with your Apple Development identity — do not switch to ad-hoc, it silently drops the Accessibility grant).

## File Structure

**Created**

| File | Responsibility |
|---|---|
| `Sources/BeamhookKit/TargetLauncher.swift` | `AppLaunching` / `Sleeping` seams, `TaskSleeper`, `TargetLaunchOutcome`, and the `TargetLauncher` sequence. |
| `Sources/BeamhookKit/LaunchOnPlayPreference.swift` | The default-ON UserDefaults rule for the setting. |
| `Sources/Beamhook/System/WorkspaceAppLauncher.swift` | `AppLaunching` via `NSWorkspace`. |
| `Sources/Beamhook/UI/AgentWindowPresenter.swift` | Ref-counted activation-policy handling for the app's windows. |
| `Sources/Beamhook/UI/SettingsWindow.swift` | Hosts `SettingsView` in a real window. |
| `Sources/Beamhook/UI/SettingsView.swift` | The General + Apps tabs. |
| `Tests/BeamhookKitTests/TargetLauncherTests.swift` | Launch sequence tests. |
| `Tests/BeamhookKitTests/LaunchOnPlayPreferenceTests.swift` | Default-ON rule. |
| `Tests/BeamhookTests/WorkspaceAppLauncherTests.swift` | Not-installed path. |
| `Tests/BeamhookTests/AgentWindowPresenterTests.swift` | Ref-count behavior. |

**Modified:** `Tests/BeamhookKitTests/Mocks.swift` (two new mocks), `Sources/Beamhook/AppState.swift` (wiring + setting), `Sources/Beamhook/UI/HookHUD.swift` (`.launching` case), `Sources/Beamhook/UI/AddAppView.swift` (use the presenter), `Sources/Beamhook/UI/MenuContentView.swift` (gear button, drop `SettingsSection`), `README.md`, `CLAUDE.md`.

**Deleted:** `Sources/Beamhook/UI/SettingsSection.swift`.

---

### Task 1: `TargetLauncher` and its seams (BeamhookKit)

**Files:**
- Create: `Sources/BeamhookKit/TargetLauncher.swift`
- Create: `Tests/BeamhookKitTests/TargetLauncherTests.swift`
- Modify: `Tests/BeamhookKitTests/Mocks.swift` (append the two new mocks)

**Interfaces:**
- Consumes: `MediaApp`, `MediaCommand`, `ScriptRunning` from `Sources/BeamhookKit/MediaApp.swift`; the existing `MockMediaApp` and `InlineScriptRunner` from `Mocks.swift`.
- Produces:
  - `public protocol AppLaunching { @MainActor func launch(bundleID: String) async -> Bool }`
  - `public protocol Sleeping { @MainActor func sleep(seconds: Double) async }`
  - `public struct TaskSleeper: Sleeping`
  - `public enum TargetLaunchOutcome: Equatable { case skipped, notInstalled, timedOut, alreadyPlaying, played }`
  - `@MainActor public final class TargetLauncher` with
    `init(launcher: AppLaunching, sleeper: Sleeping = TaskSleeper(), runner: ScriptRunning, timeout: Double = 15, pollInterval: Double = 0.25)` and
    `func launchAndPlay(_ app: MediaApp, isStillHooked: @escaping @MainActor () -> Bool, onLaunchStarted: @escaping @MainActor () -> Void) async -> TargetLaunchOutcome`

Both protocols are `@MainActor`-isolated on purpose: every caller (AppState, and the real `NSWorkspace` launch) is already on the main actor, and it keeps mocks and captured test state free of data-race questions. `TaskSleeper` still suspends rather than blocking, so an isolated sleep does not stall the main thread.

One deviation from the spec: it put `TaskSleeper` next to `WorkspaceAppLauncher` in the app target. It lives in the kit instead — it is pure Foundation (`Task.sleep`), so it needs nothing from AppKit, and keeping it beside the protocol it implements means the kit's own tests can use the real one.

- [ ] **Step 1: Add the two mocks**

Append to `Tests/BeamhookKitTests/Mocks.swift`:

```swift
/// Stands in for the system launcher. `onLaunch` runs inside `launch`, after the
/// call is recorded, so a test can model what happens while a launch is in
/// flight — including re-entering TargetLauncher to test single-flight.
@MainActor
final class MockAppLauncher: AppLaunching {
    var installed = true
    var launchedBundleIDs: [String] = []
    var onLaunch: (() async -> Void)?

    func launch(bundleID: String) async -> Bool {
        launchedBundleIDs.append(bundleID)
        await onLaunch?()
        return installed
    }
}

/// Sleeps instantly and counts. `onSleep` receives the 1-based poll number, so a
/// test can flip an app to ready on the Nth poll with no real waiting.
@MainActor
final class CountingSleeper: Sleeping {
    private(set) var sleepCount = 0
    var onSleep: ((Int) -> Void)?

    func sleep(seconds: Double) async {
        sleepCount += 1
        onSleep?(sleepCount)
    }
}
```

- [ ] **Step 2: Write the failing tests**

Create `Tests/BeamhookKitTests/TargetLauncherTests.swift`:

```swift
import XCTest
@testable import BeamhookKit

@MainActor
final class TargetLauncherTests: XCTestCase {
    private func makeSubject(launcher: MockAppLauncher,
                             sleeper: CountingSleeper,
                             timeout: Double = 15,
                             pollInterval: Double = 0.25) -> TargetLauncher {
        TargetLauncher(launcher: launcher, sleeper: sleeper,
                       runner: InlineScriptRunner(),
                       timeout: timeout, pollInterval: pollInterval)
    }

    /// Not running: launch it, wait for readiness, then play.
    func testLaunchesAndPlaysWhenNotRunning() async {
        let app = MockMediaApp(id: "spotify", isRunning: false)
        app.readyValue = false
        let launcher = MockAppLauncher()
        let sleeper = CountingSleeper()
        launcher.onLaunch = { app.isRunning = true }        // running, still launching
        sleeper.onSleep = { count in if count == 3 { app.readyValue = true } }
        let subject = makeSubject(launcher: launcher, sleeper: sleeper)
        var startedCount = 0

        let outcome = await subject.launchAndPlay(app,
                                                  isStillHooked: { true },
                                                  onLaunchStarted: { startedCount += 1 })

        XCTAssertEqual(outcome, .played)
        XCTAssertEqual(launcher.launchedBundleIDs, ["com.example.spotify"])
        XCTAssertEqual(app.performedCommands, [.playPause])
        XCTAssertEqual(sleeper.sleepCount, 3)
        XCTAssertEqual(startedCount, 1)
    }

    /// Running but still launching: don't relaunch, just wait and play. This is
    /// the press that TargetManager.route drops today.
    func testWaitsWithoutLaunchingWhenAlreadyRunning() async {
        let app = MockMediaApp(id: "spotify", isRunning: true)
        app.readyValue = false
        let launcher = MockAppLauncher()
        let sleeper = CountingSleeper()
        sleeper.onSleep = { count in if count == 2 { app.readyValue = true } }
        let subject = makeSubject(launcher: launcher, sleeper: sleeper)

        let outcome = await subject.launchAndPlay(app,
                                                  isStillHooked: { true },
                                                  onLaunchStarted: {})

        XCTAssertEqual(outcome, .played)
        XCTAssertTrue(launcher.launchedBundleIDs.isEmpty)
        XCTAssertEqual(app.performedCommands, [.playPause])
    }

    func testNotInstalledSendsNothingAndDoesNotAnnounce() async {
        let app = MockMediaApp(id: "spotify", isRunning: false)
        app.readyValue = false
        let launcher = MockAppLauncher()
        launcher.installed = false
        let sleeper = CountingSleeper()
        let subject = makeSubject(launcher: launcher, sleeper: sleeper)
        var startedCount = 0

        let outcome = await subject.launchAndPlay(app,
                                                  isStillHooked: { true },
                                                  onLaunchStarted: { startedCount += 1 })

        XCTAssertEqual(outcome, .notInstalled)
        XCTAssertTrue(app.performedCommands.isEmpty)
        XCTAssertEqual(startedCount, 0)
        XCTAssertEqual(sleeper.sleepCount, 0)
    }

    /// The wait is bounded: 1s / 0.25s = 4 polls, then give up.
    func testTimesOutWhenReadinessNeverArrives() async {
        let app = MockMediaApp(id: "spotify", isRunning: false)
        app.readyValue = false
        let launcher = MockAppLauncher()
        let sleeper = CountingSleeper()
        let subject = makeSubject(launcher: launcher, sleeper: sleeper,
                                  timeout: 1.0, pollInterval: 0.25)

        let outcome = await subject.launchAndPlay(app,
                                                  isStillHooked: { true },
                                                  onLaunchStarted: {})

        XCTAssertEqual(outcome, .timedOut)
        XCTAssertTrue(app.performedCommands.isEmpty)
        XCTAssertEqual(sleeper.sleepCount, 4)
    }

    /// An app that resumes on its own must not be paused by our playPause.
    func testAlreadyPlayingSendsNothing() async {
        let app = MockMediaApp(id: "spotify", isRunning: true)
        app.playingState = true
        let launcher = MockAppLauncher()
        let sleeper = CountingSleeper()
        let subject = makeSubject(launcher: launcher, sleeper: sleeper)

        let outcome = await subject.launchAndPlay(app,
                                                  isStillHooked: { true },
                                                  onLaunchStarted: {})

        XCTAssertEqual(outcome, .alreadyPlaying)
        XCTAssertTrue(app.performedCommands.isEmpty)
    }

    /// Unknown play state (no playStateScript) still plays — a freshly launched
    /// app is overwhelmingly likely to be paused.
    func testUnknownPlayStatePlays() async {
        let app = MockMediaApp(id: "spotify", isRunning: true)
        app.playingState = nil
        let launcher = MockAppLauncher()
        let sleeper = CountingSleeper()
        let subject = makeSubject(launcher: launcher, sleeper: sleeper)

        let outcome = await subject.launchAndPlay(app,
                                                  isStillHooked: { true },
                                                  onLaunchStarted: {})

        XCTAssertEqual(outcome, .played)
        XCTAssertEqual(app.performedCommands, [.playPause])
    }

    /// Single-flight: a second press during the launch must not queue another
    /// playPause behind the first (which would pause what just started).
    func testSecondCallDuringLaunchIsSkipped() async {
        let app = MockMediaApp(id: "spotify", isRunning: false)
        app.readyValue = false
        let launcher = MockAppLauncher()
        let sleeper = CountingSleeper()
        sleeper.onSleep = { _ in app.isRunning = true; app.readyValue = true }
        let subject = makeSubject(launcher: launcher, sleeper: sleeper)
        var reentrantOutcome: TargetLaunchOutcome?
        launcher.onLaunch = { [weak subject] in
            guard let subject else { return }
            reentrantOutcome = await subject.launchAndPlay(app,
                                                           isStillHooked: { true },
                                                           onLaunchStarted: {})
        }

        let outcome = await subject.launchAndPlay(app,
                                                  isStillHooked: { true },
                                                  onLaunchStarted: {})

        XCTAssertEqual(outcome, .played)
        XCTAssertEqual(reentrantOutcome, .skipped)
        XCTAssertEqual(launcher.launchedBundleIDs, ["com.example.spotify"])
        XCTAssertEqual(app.performedCommands, [.playPause])
    }

    /// Hooking a different app mid-launch must not play the old one.
    func testTargetChangedDuringLaunchSkipsPlay() async {
        let app = MockMediaApp(id: "spotify", isRunning: false)
        app.readyValue = false
        let launcher = MockAppLauncher()
        let sleeper = CountingSleeper()
        var stillHooked = true
        sleeper.onSleep = { _ in app.readyValue = true; stillHooked = false }
        let subject = makeSubject(launcher: launcher, sleeper: sleeper)

        let outcome = await subject.launchAndPlay(app,
                                                  isStillHooked: { stillHooked },
                                                  onLaunchStarted: {})

        XCTAssertEqual(outcome, .skipped)
        XCTAssertTrue(app.performedCommands.isEmpty)
    }
}
```

- [ ] **Step 3: Regenerate the project and run the tests to verify they fail**

```bash
cd /Users/olli/git/beamhook && xcodegen generate && xcodebuild test -project Beamhook.xcodeproj -scheme BeamhookKit -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:BeamhookKitTests/TargetLauncherTests
```

Expected: compile failure — `cannot find 'TargetLauncher' in scope` (and `AppLaunching` / `Sleeping` unresolved in `Mocks.swift`).

- [ ] **Step 4: Write the implementation**

Create `Sources/BeamhookKit/TargetLauncher.swift`:

```swift
import Foundation

/// Starts an app. Main-actor isolated: the only implementation asks NSWorkspace,
/// which is a main-thread API, and it keeps every caller on one actor.
@MainActor
public protocol AppLaunching {
    /// Asks the system to launch this app. False when it isn't installed.
    func launch(bundleID: String) async -> Bool
}

/// Test seam so the readiness poll runs instantly under test.
@MainActor
public protocol Sleeping {
    func sleep(seconds: Double) async
}

public struct TaskSleeper: Sleeping {
    public init() {}
    public func sleep(seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}

public enum TargetLaunchOutcome: Equatable {
    /// A launch was already in flight, or the hook moved while we waited.
    case skipped
    case notInstalled
    case timedOut
    /// The app resumed playback on its own; nothing was sent.
    case alreadyPlaying
    case played
}

/// Launches the hooked app and starts playback, for a play/pause press that
/// would otherwise be swallowed with nothing to act on.
///
/// Deliberately NOT done by letting AppleScript launch the app implicitly: that
/// Apple-event send blocks until the target finishes launching (the ~2 minute
/// stall behind the July 2026 freeze) and would sit on the serial command lane
/// with every later key press queued behind it. It also cannot work for
/// menu-driven targets, which have no scripting dictionary at all.
@MainActor
public final class TargetLauncher {
    private let launcher: AppLaunching
    private let sleeper: Sleeping
    private let runner: ScriptRunning
    private let timeout: Double
    private let pollInterval: Double
    private var isLaunching = false

    /// - Parameters:
    ///   - runner: the *command* lane, so the play it sends is serialized with
    ///     the user's other key presses.
    ///   - timeout: how long to wait for readiness before giving up quietly.
    public init(launcher: AppLaunching,
                sleeper: Sleeping = TaskSleeper(),
                runner: ScriptRunning,
                timeout: Double = 15,
                pollInterval: Double = 0.25) {
        self.launcher = launcher
        self.sleeper = sleeper
        self.runner = runner
        self.timeout = timeout
        self.pollInterval = pollInterval
    }

    /// - Parameters:
    ///   - isStillHooked: re-checked after the wait; the user can change target
    ///     during a cold start, and playing the old one would be wrong.
    ///   - onLaunchStarted: fires exactly once, only when something really is
    ///     starting — drives the "Starting …" HUD.
    public func launchAndPlay(_ app: MediaApp,
                              isStillHooked: @escaping @MainActor () -> Bool,
                              onLaunchStarted: @escaping @MainActor () -> Void)
        async -> TargetLaunchOutcome {
        guard !isLaunching else { return .skipped }
        isLaunching = true
        defer { isLaunching = false }

        // Already running means mid-launch: wait for it rather than relaunching.
        if !app.isRunning {
            guard await launcher.launch(bundleID: app.bundleID) else { return .notInstalled }
        }
        onLaunchStarted()

        var waited = 0.0
        while !app.isReady {
            if waited >= timeout { return .timedOut }
            await sleeper.sleep(seconds: pollInterval)
            waited += pollInterval
        }

        guard isStillHooked() else { return .skipped }

        return await runner.run {
            // An app that resumed on its own would be PAUSED by an unconditional
            // playPause. Unknown state (nil) counts as not playing.
            if app.isPlaying() == true { return .alreadyPlaying }
            app.perform(.playPause)
            return .played
        }
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

```bash
cd /Users/olli/git/beamhook && xcodebuild test -project Beamhook.xcodeproj -scheme BeamhookKit -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:BeamhookKitTests/TargetLauncherTests
```

Expected: `** TEST SUCCEEDED **`, 8 tests.

- [ ] **Step 6: Run the whole kit suite for regressions**

```bash
cd /Users/olli/git/beamhook && xcodebuild test -project Beamhook.xcodeproj -scheme BeamhookKit -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 7: Commit**

```bash
git add Sources/BeamhookKit/TargetLauncher.swift Tests/BeamhookKitTests/TargetLauncherTests.swift Tests/BeamhookKitTests/Mocks.swift && git commit -m "Add TargetLauncher: launch a quit target, wait for it, then play"
```

---

### Task 2: `WorkspaceAppLauncher` (app target)

**Files:**
- Create: `Sources/Beamhook/System/WorkspaceAppLauncher.swift`
- Create: `Tests/BeamhookTests/WorkspaceAppLauncherTests.swift`

**Interfaces:**
- Consumes: `AppLaunching` from Task 1.
- Produces: `@MainActor final class WorkspaceAppLauncher: AppLaunching`.

- [ ] **Step 1: Write the failing test**

Create `Tests/BeamhookTests/WorkspaceAppLauncherTests.swift`:

```swift
import XCTest
@testable import Beamhook

@MainActor
final class WorkspaceAppLauncherTests: XCTestCase {
    /// A bundle id with no app on disk resolves to no URL, so nothing is
    /// launched and the caller learns the target isn't installed.
    func testUninstalledBundleIDReportsNotInstalled() async {
        let launcher = WorkspaceAppLauncher()
        let launched = await launcher.launch(bundleID: "com.beamhook.tests.not.installed")
        XCTAssertFalse(launched)
    }
}
```

- [ ] **Step 2: Regenerate and run it to verify it fails**

```bash
cd /Users/olli/git/beamhook && xcodegen generate && xcodebuild test -project Beamhook.xcodeproj -scheme Beamhook -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:BeamhookTests/WorkspaceAppLauncherTests
```

Expected: compile failure — `cannot find 'WorkspaceAppLauncher' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/Beamhook/System/WorkspaceAppLauncher.swift`:

```swift
import AppKit
import BeamhookKit

/// Launches a target through NSWorkspace. Asynchronous by construction, so a
/// slow-starting app never blocks the main thread or the media-key tap.
@MainActor
final class WorkspaceAppLauncher: AppLaunching {
    func launch(bundleID: String) async -> Bool {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return false   // not installed
        }
        let configuration = NSWorkspace.OpenConfiguration()
        // Pressing play must not pull focus out of whatever the user is doing.
        configuration.activates = false
        configuration.addsToRecentItems = false
        do {
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            return true
        } catch {
            NSLog("WorkspaceAppLauncher: failed to launch \(bundleID): \(error)")
            return false
        }
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd /Users/olli/git/beamhook && xcodebuild test -project Beamhook.xcodeproj -scheme Beamhook -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:BeamhookTests/WorkspaceAppLauncherTests
```

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add Sources/Beamhook/System/WorkspaceAppLauncher.swift Tests/BeamhookTests/WorkspaceAppLauncherTests.swift && git commit -m "Add WorkspaceAppLauncher"
```

---

### Task 3: Setting, HUD case, and `AppState` wiring — the feature works end to end

**Files:**
- Create: `Sources/BeamhookKit/LaunchOnPlayPreference.swift`
- Create: `Tests/BeamhookKitTests/LaunchOnPlayPreferenceTests.swift`
- Modify: `Sources/Beamhook/UI/HookHUD.swift` (the `Presentation` enum at :14-30, the `present` switch at :114-128, and add a `showLaunching` next to `showVolume` at :88)
- Modify: `Sources/Beamhook/AppState.swift` (properties near :139, `handleKey` at :228-243, `togglePlayPauseTarget` at :374-397)

**Interfaces:**
- Consumes: `TargetLauncher`, `TargetLaunchOutcome` (Task 1); `WorkspaceAppLauncher` (Task 2).
- Produces:
  - `public enum LaunchOnPlayPreference` with `static let storageKey = "launchTargetOnPlay"`, `static func isEnabled(_ defaults: UserDefaults) -> Bool`, `static func setEnabled(_ enabled: Bool, in defaults: UserDefaults)`
  - `AppState.launchTargetOnPlay: Bool` (`@Published`) and `AppState.setLaunchTargetOnPlay(_ on: Bool)` — bound by the General tab in Task 5.
  - `HookHUD.showLaunching(appName: String)`

- [ ] **Step 1: Write the failing preference test**

Create `Tests/BeamhookKitTests/LaunchOnPlayPreferenceTests.swift`:

```swift
import XCTest
@testable import BeamhookKit

final class LaunchOnPlayPreferenceTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let suite = "LaunchOnPlayPreferenceTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    /// Absent means ON: a quit target's play/pause does nothing today, so
    /// launching is the better default.
    func testDefaultsToEnabledWhenUnset() {
        XCTAssertTrue(LaunchOnPlayPreference.isEnabled(makeDefaults()))
    }

    func testRespectsAnExplicitOff() {
        let defaults = makeDefaults()
        LaunchOnPlayPreference.setEnabled(false, in: defaults)
        XCTAssertFalse(LaunchOnPlayPreference.isEnabled(defaults))
    }

    func testRespectsAnExplicitOn() {
        let defaults = makeDefaults()
        LaunchOnPlayPreference.setEnabled(false, in: defaults)
        LaunchOnPlayPreference.setEnabled(true, in: defaults)
        XCTAssertTrue(LaunchOnPlayPreference.isEnabled(defaults))
    }
}
```

- [ ] **Step 2: Regenerate and run it to verify it fails**

```bash
cd /Users/olli/git/beamhook && xcodegen generate && xcodebuild test -project Beamhook.xcodeproj -scheme BeamhookKit -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:BeamhookKitTests/LaunchOnPlayPreferenceTests
```

Expected: compile failure — `cannot find 'LaunchOnPlayPreference' in scope`.

- [ ] **Step 3: Write the preference helper**

Create `Sources/BeamhookKit/LaunchOnPlayPreference.swift`:

```swift
import Foundation

/// Whether a play/pause press may start the hooked app when it isn't running.
public enum LaunchOnPlayPreference {
    public static let storageKey = "launchTargetOnPlay"

    /// Absent means ON. Unlike the volume-key hijack — which silently takes a
    /// working system key away and so must be opted into — this only fills a
    /// press that currently does nothing at all.
    public static func isEnabled(_ defaults: UserDefaults) -> Bool {
        defaults.object(forKey: storageKey) as? Bool ?? true
    }

    public static func setEnabled(_ enabled: Bool, in defaults: UserDefaults) {
        defaults.set(enabled, forKey: storageKey)
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd /Users/olli/git/beamhook && xcodebuild test -project Beamhook.xcodeproj -scheme BeamhookKit -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:BeamhookKitTests/LaunchOnPlayPreferenceTests
```

Expected: `** TEST SUCCEEDED **`, 3 tests.

- [ ] **Step 5: Add the HUD case**

In `Sources/Beamhook/UI/HookHUD.swift`, add the case to `Presentation` (currently `hooked` and `volume`):

```swift
        case hooked(appName: String, volumeKeysHijacked: Bool)
        case volume(appName: String, percent: Int)
        case launching(appName: String)
```

Extend its two computed properties:

```swift
        var appName: String {
            switch self {
            case .hooked(let appName, _), .volume(let appName, _), .launching(let appName): appName
            }
        }

        var hideDelay: TimeInterval {
            switch self {
            case .hooked(_, let volumeKeysHijacked): volumeKeysHijacked ? 3.0 : 2.0
            case .volume: 1.5
            case .launching: 2.0
            }
        }
```

Add the public entry point next to `showVolume`:

```swift
    /// Flash "Starting <appName>…" while a hooked app that wasn't running
    /// launches, so a cold start doesn't read as a dead key press.
    func showLaunching(appName: String) {
        show(.launching(appName: appName))
    }
```

And the render arm inside `present`, after the `.volume` case:

```swift
        case .launching(let appName):
            label?.stringValue = "Starting \(appName)…"
            detailLabel?.isHidden = true
            hookIcon?.isHidden = false
            volumeRow?.isHidden = true
```

- [ ] **Step 6: Wire it into `AppState`**

In `Sources/Beamhook/AppState.swift`, add a stored property beside the other collaborators (near `private let browserMediaController = BrowserMediaController()`):

```swift
    /// Launches the hooked app for a play/pause press it would otherwise swallow.
    private let targetLauncher: TargetLauncher
```

Add the published setting next to `loginItemEnabled`:

```swift
    /// Whether play/pause may start the hooked app when it isn't running.
    @Published var launchTargetOnPlay: Bool = LaunchOnPlayPreference.isEnabled(.standard)
```

In `init`, after `let targetManager = TargetManager(...)` and before the `self.` assignments, build the launcher on the **command** lane:

```swift
        self.targetLauncher = TargetLauncher(launcher: WorkspaceAppLauncher(), runner: scripting)
```

Replace the non-browser arm of `handleKey`'s `default:` branch:

```swift
            } else {
                Task {
                    let routed = await self.targetManager.route(key)
                    // route() returning false means nothing was delivered — no
                    // target, or the app isn't ready. Only play/pause gets the
                    // launch fallback: next/previous on a quit app have no
                    // meaningful target.
                    guard !routed, command == .playPause else { return }
                    await self.launchTargetAndPlay()
                }
            }
```

Add the helper below `handleKey`:

```swift
    /// Start the hooked app, wait for it, then play. Browser targets are
    /// excluded: when a browser isn't running Beamhook hands the transport keys
    /// back to macOS (`refreshBrowserMedia`), and a freshly launched browser has
    /// no media tab to act on anyway.
    private func launchTargetAndPlay() async {
        guard launchTargetOnPlay,
              !selectedTargetIsBrowser,
              let id = selectedTargetID,
              let app = registry.app(withID: id) else { return }
        let displayName = availableApps.first { $0.id == id }?.displayName ?? app.displayName
        _ = await targetLauncher.launchAndPlay(
            app,
            isStillHooked: { [weak self] in self?.selectedTargetID == id },
            onLaunchStarted: { HookHUD.shared.showLaunching(appName: displayName) })
    }
```

Give the popover's own play button the same fallback — replace the `else` arm of `togglePlayPauseTarget`:

```swift
        } else {
            guard let id = context.targetID, let app = registry.app(withID: id) else {
                return false
            }
            let performed = await scripting.run {
                guard app.isReady else { return false }
                app.perform(.playPause)
                return true
            }
            // Nothing delivered: the app isn't running. Start it instead. The
            // false return keeps the optimistic icon honest — the periodic poll
            // reflects playback once the app is actually up.
            if !performed { await launchTargetAndPlay() }
            return performed
        }
```

Add the setter next to `setLoginItem`:

```swift
    func setLaunchTargetOnPlay(_ on: Bool) {
        launchTargetOnPlay = on
        LaunchOnPlayPreference.setEnabled(on, in: .standard)
    }
```

- [ ] **Step 7: Build and run the full suites**

```bash
cd /Users/olli/git/beamhook && xcodebuild build -project Beamhook.xcodeproj -scheme Beamhook -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO && xcodebuild test -project Beamhook.xcodeproj -scheme BeamhookKit -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO && xcodebuild test -project Beamhook.xcodeproj -scheme Beamhook -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

Expected: `** BUILD SUCCEEDED **` then two `** TEST SUCCEEDED **`.

- [ ] **Step 8: Manual verification**

```bash
cd /Users/olli/git/beamhook && ./run.sh
```

Check, in order:
1. Hook Spotify, quit Spotify, press the play key → "Starting Spotify…" HUD, Spotify launches **without stealing focus**, playback starts.
2. Quit Spotify, press play twice within a second → one launch, still playing (not paused by the second press).
3. Quit Spotify, press **next** → nothing launches (play/pause only).
4. Hook Safari and quit Safari, press play → unchanged: macOS handles it, Beamhook launches nothing.
5. With Spotify quit, open the popover and click its play button → same launch behavior.

If the media keys do nothing at all, the dev build needs its own Accessibility grant (System Settings → Privacy & Security → Accessibility); the installed copy's grant does not carry over.

- [ ] **Step 9: Commit**

```bash
git add Sources/BeamhookKit/LaunchOnPlayPreference.swift Tests/BeamhookKitTests/LaunchOnPlayPreferenceTests.swift Sources/Beamhook/UI/HookHUD.swift Sources/Beamhook/AppState.swift && git commit -m "Launch the hooked app on play/pause when it isn't running"
```

---

### Task 4: `AgentWindowPresenter` — ref-counted activation policy

Beamhook is an agent app (`LSUIElement`), so a window can only become key while the activation policy is `.regular`. `AddAppWindow` flips it on show and back to `.accessory` on `willClose`. With a second window (Task 5) that is a bug: closing Add-an-app while Settings is open drops the app to `.accessory` with a window still up.

**Files:**
- Create: `Sources/Beamhook/UI/AgentWindowPresenter.swift`
- Create: `Tests/BeamhookTests/AgentWindowPresenterTests.swift`
- Modify: `Sources/Beamhook/UI/AddAppView.swift:19-45` (`AddAppWindow.show`)

**Interfaces:**
- Produces: `@MainActor final class AgentWindowPresenter` with `static let shared`, `init(setPolicy: @escaping (NSApplication.ActivationPolicy) -> Void = { NSApp.setActivationPolicy($0) })`, `func present(_ window: NSWindow)`, and `func beginPresenting(_ window: NSWindow)` (bookkeeping only — used by tests so no window is put on screen). Task 5's `SettingsWindow` calls `present`.

- [ ] **Step 1: Write the failing test**

Create `Tests/BeamhookTests/AgentWindowPresenterTests.swift`:

```swift
import AppKit
import XCTest
@testable import Beamhook

@MainActor
final class AgentWindowPresenterTests: XCTestCase {
    private func makeWindow() -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        return w
    }

    /// The app must stay .regular until the LAST window closes, or the window
    /// still on screen loses its ability to become key.
    func testPolicyRevertsOnlyAfterTheLastWindowCloses() {
        var policies: [NSApplication.ActivationPolicy] = []
        let presenter = AgentWindowPresenter(setPolicy: { policies.append($0) })
        let first = makeWindow()
        let second = makeWindow()

        presenter.beginPresenting(first)
        presenter.beginPresenting(second)
        first.close()

        XCTAssertEqual(policies, [.regular, .regular])

        second.close()

        XCTAssertEqual(policies, [.regular, .regular, .accessory])
    }

    /// AddAppWindow reuses one window across shows, so re-presenting the same
    /// window must not leave a phantom open count behind.
    func testRepresentingTheSameWindowDoesNotDoubleCount() {
        var policies: [NSApplication.ActivationPolicy] = []
        let presenter = AgentWindowPresenter(setPolicy: { policies.append($0) })
        let window = makeWindow()

        presenter.beginPresenting(window)
        presenter.beginPresenting(window)
        window.close()

        XCTAssertEqual(policies, [.regular, .regular, .accessory])
    }
}
```

- [ ] **Step 2: Regenerate and run it to verify it fails**

```bash
cd /Users/olli/git/beamhook && xcodegen generate && xcodebuild test -project Beamhook.xcodeproj -scheme Beamhook -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:BeamhookTests/AgentWindowPresenterTests
```

Expected: compile failure — `cannot find 'AgentWindowPresenter' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/Beamhook/UI/AgentWindowPresenter.swift`:

```swift
import AppKit

/// Beamhook is an agent app (LSUIElement): its windows can only become key while
/// the activation policy is `.regular`. Windows therefore flip it on the way in —
/// but with more than one open, whichever closes first must NOT drop the app back
/// to `.accessory` while another is still up. This tracks them by identity, so
/// re-showing an already-open window (AddAppWindow reuses its window) is a no-op.
@MainActor
final class AgentWindowPresenter {
    static let shared = AgentWindowPresenter()

    private var open: Set<ObjectIdentifier> = []
    private var observed: Set<ObjectIdentifier> = []
    private let setPolicy: (NSApplication.ActivationPolicy) -> Void

    init(setPolicy: @escaping (NSApplication.ActivationPolicy) -> Void = {
        NSApp.setActivationPolicy($0)
    }) {
        self.setPolicy = setPolicy
    }

    /// Bring `window` up as a real, focusable window.
    func present(_ window: NSWindow) {
        beginPresenting(window)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Policy + lifecycle bookkeeping, without putting anything on screen.
    func beginPresenting(_ window: NSWindow) {
        let key = ObjectIdentifier(window)
        if observed.insert(key).inserted {
            // queue: nil so the callback runs synchronously on the poster's
            // thread (willClose is always posted on main), which keeps the
            // bookkeeping — and its tests — free of ordering surprises.
            NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: nil
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.didClose(key) }
            }
        }
        open.insert(key)
        setPolicy(.regular)
    }

    private func didClose(_ key: ObjectIdentifier) {
        open.remove(key)
        if open.isEmpty { setPolicy(.accessory) }
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd /Users/olli/git/beamhook && xcodebuild test -project Beamhook.xcodeproj -scheme Beamhook -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:BeamhookTests/AgentWindowPresenterTests
```

Expected: `** TEST SUCCEEDED **`, 2 tests.

- [ ] **Step 5: Move `AddAppWindow` onto the presenter**

In `Sources/Beamhook/UI/AddAppView.swift`, delete the `willCloseNotification` observer from the `else` branch and replace the trailing three lines (`NSApp.setActivationPolicy(.regular)`, `NSApp.activate(...)`, `w.makeKeyAndOrderFront(nil)`) with:

```swift
        AgentWindowPresenter.shared.present(w)
```

So the whole tail of `show` reads:

```swift
        let w: NSWindow
        if let existing = window {
            w = existing
            w.contentViewController = hosting
        } else {
            w = NSWindow(contentViewController: hosting)
            w.title = "Add an App"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }

        AgentWindowPresenter.shared.present(w)
```

Update the type's doc comment: the activation-policy explanation now lives in `AgentWindowPresenter`, so shorten it to note that it opens a real window (not a sheet, which would dismiss the popover) and presents it through `AgentWindowPresenter`.

- [ ] **Step 6: Build, run the app suite, and check Add-an-app still works**

```bash
cd /Users/olli/git/beamhook && xcodebuild test -project Beamhook.xcodeproj -scheme Beamhook -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO && ./run.sh
```

Expected: `** TEST SUCCEEDED **`. In the app: open the popover → "Add an app…" → the window appears, accepts typing in its fields, and closing it returns the app to agent behavior (no Dock icon).

- [ ] **Step 7: Commit**

```bash
git add Sources/Beamhook/UI/AgentWindowPresenter.swift Tests/BeamhookTests/AgentWindowPresenterTests.swift Sources/Beamhook/UI/AddAppView.swift && git commit -m "Ref-count activation policy across Beamhook's windows"
```

---

### Task 5: The Settings window

**Files:**
- Create: `Sources/Beamhook/UI/SettingsWindow.swift`
- Create: `Sources/Beamhook/UI/SettingsView.swift`
- Delete: `Sources/Beamhook/UI/SettingsSection.swift`
- Modify: `Sources/Beamhook/UI/MenuContentView.swift:108-129` (drop `SettingsSection`, add the gear button)

**Interfaces:**
- Consumes: `AgentWindowPresenter` (Task 4); `AppState.launchTargetOnPlay` / `setLaunchTargetOnPlay` (Task 3); `AddAppWindow.shared.show(state:)`; `Notification.Name.closeBeamhookMenu`.
- Produces: `@MainActor final class SettingsWindow` with `static let shared` and `func show(state: AppState)`.

- [ ] **Step 1: Create the view**

Create `Sources/Beamhook/UI/SettingsView.swift`:

```swift
import SwiftUI
import BeamhookKit

/// Beamhook's settings. Presented in a real window by `SettingsWindow` — never a
/// sheet, which would dismiss the menu-bar popover it was opened from.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }
            AppsSettingsTab()
                .tabItem { Label("Apps", systemImage: "square.grid.2x2") }
        }
        .padding(20)
        .frame(width: 440, height: 300)
    }
}

private struct GeneralSettingsTab: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Toggle("Launch at login", isOn: Binding(
                get: { state.loginItemEnabled },
                set: { state.setLoginItem($0) }))

            VStack(alignment: .leading, spacing: 4) {
                Toggle("Launch the hooked app on play/pause", isOn: Binding(
                    get: { state.launchTargetOnPlay },
                    set: { state.setLaunchTargetOnPlay($0) }))
                Text("Starts the app if it isn't running.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .toggleStyle(.switch)
        .padding(.top, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AppsSettingsTab: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                AddAppWindow.shared.show(state: state)
            } label: {
                Label("Add an app…", systemImage: "plus")
            }

            let custom = state.availableApps.filter { !$0.isBuiltIn }
            if custom.isEmpty {
                Text("No custom apps yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                List(custom) { app in
                    HStack {
                        Text(app.displayName)
                        Spacer()
                        Button(role: .destructive) {
                            removeCustom(app)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove \(app.displayName)")
                    }
                }
            }

            Spacer()
        }
        .padding(.top, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func removeCustom(_ app: AppDefinition) {
        var defs = state.store.loadUserDefined()
        defs.removeAll { $0.id == app.id }
        state.store.saveUserDefined(defs)
        state.reloadApps()
        if state.selectedTargetID == app.id {
            state.setTarget(nil)
        }
    }
}
```

- [ ] **Step 2: Create the window**

Create `Sources/Beamhook/UI/SettingsWindow.swift`:

```swift
import AppKit
import SwiftUI

/// Opens Settings in a real window and asks the popover to close first — a sheet
/// would dismiss the popover with it. Reuses one window across shows;
/// `AgentWindowPresenter` owns the activation-policy handling.
@MainActor
final class SettingsWindow {
    static let shared = SettingsWindow()
    private var window: NSWindow?

    func show(state: AppState) {
        NotificationCenter.default.post(name: .closeBeamhookMenu, object: nil)

        let hosting = NSHostingController(rootView: SettingsView().environmentObject(state))

        let w: NSWindow
        if let existing = window {
            w = existing
            w.contentViewController = hosting
        } else {
            w = NSWindow(contentViewController: hosting)
            w.title = "Beamhook Settings"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }

        AgentWindowPresenter.shared.present(w)
    }

    func hide() { window?.close() }
}
```

- [ ] **Step 3: Update the popover and delete `SettingsSection`**

In `Sources/Beamhook/UI/MenuContentView.swift`, delete these two lines (currently :108-109):

```swift
            Divider()
            SettingsSection()
```

In the footer `HStack` below, insert a gear button before the Quit button:

```swift
                Spacer(minLength: 8)
                Button {
                    SettingsWindow.shared.show(state: state)
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .help("Settings")
                Button("Quit") { NSApplication.shared.terminate(nil) }
```

Then delete the old file:

```bash
git rm Sources/Beamhook/UI/SettingsSection.swift
```

- [ ] **Step 4: Regenerate, build, and run the suites**

```bash
cd /Users/olli/git/beamhook && xcodegen generate && xcodebuild test -project Beamhook.xcodeproj -scheme Beamhook -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO && xcodebuild test -project Beamhook.xcodeproj -scheme BeamhookKit -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

Expected: two `** TEST SUCCEEDED **`. A build error naming `SettingsSection` means the project wasn't regenerated after the delete.

- [ ] **Step 5: Manual verification**

```bash
cd /Users/olli/git/beamhook && ./run.sh
```

Check:
1. The popover no longer shows the login toggle / Add-an-app / custom list, and is visibly shorter. The gear sits in the footer next to Quit.
2. Clicking the gear closes the popover and opens "Beamhook Settings" with two tabs.
3. General: both toggles reflect current state and persist across an app relaunch (turn "Launch the hooked app on play/pause" off, quit, relaunch, reopen Settings — still off).
4. With the toggle off, quit Spotify and press play → nothing launches. Turn it back on → it launches.
5. Apps: "Add an app…" opens the Add window; closing **Add an app** while Settings is still open leaves Settings usable and key (this is the Task 4 ref-count). Closing both returns the app to agent behavior.
6. Adding a custom app makes it appear in the Apps list; its trash button removes it.

- [ ] **Step 6: Commit**

```bash
git add Sources/Beamhook/UI/SettingsWindow.swift Sources/Beamhook/UI/SettingsView.swift Sources/Beamhook/UI/MenuContentView.swift && git commit -m "Move settings into a two-tab Settings window"
```

---

### Task 6: Documentation

**Files:**
- Modify: `CLAUDE.md:146-151` (the "UI gotcha" section) and its Architecture file list
- Modify: `README.md` (the Features list, :39-54)

- [ ] **Step 1: Correct the stale UI gotcha**

`CLAUDE.md` currently says settings are inlined into the popover via `SettingsSection`, which this branch makes false. Replace that section's body with:

```markdown
`MenuBarExtra(.window)` popovers **dismiss when a `.sheet` takes focus** — so
anything bigger than a popover row opens in a real `NSWindow` instead
(`SettingsWindow`, `AddAppWindow`), never a sheet. Beamhook is an agent app, so
those windows go through `AgentWindowPresenter`, which flips the activation
policy to `.regular` while any of them is open and back to `.accessory` only
when the last one closes.
```

- [ ] **Step 2: Add the new files to the Architecture list**

In `CLAUDE.md`, under the `Sources/BeamhookKit/` bullets add:

```markdown
  - `TargetLauncher.swift` — launches the hooked app for a play/pause press it
    would otherwise swallow (launch → poll `isReady` → play), behind the
    `AppLaunching` / `Sleeping` seams. Never launches by Apple event: that send
    blocks until the app is up. `LaunchOnPlayPreference.swift` holds the
    default-ON setting rule.
```

Under the `Sources/Beamhook/` bullets, add `WorkspaceAppLauncher.swift` to the `System/` list and `SettingsWindow.swift` / `SettingsView.swift` / `AgentWindowPresenter.swift` to the `UI/` list (replacing `SettingsSection.swift`).

- [ ] **Step 3: Document the behavior in the README**

In `README.md`, add after the volume-key bullets (:45-46):

```markdown
- If the hooked app isn't running, play/pause starts it and begins playback. Can
  be turned off in Settings. (A menu-driven app launched with an empty queue —
  TIDAL, for instance — has nothing to play.)
```

- [ ] **Step 4: Verify the docs match the code**

Re-read the changed sections against the branch: every file named must exist, and `SettingsSection.swift` must appear nowhere.

```bash
cd /Users/olli/git/beamhook && grep -rn "SettingsSection" README.md CLAUDE.md Sources/ ; echo "exit: $? (1 = clean, no matches)"
```

Expected: no matches.

- [ ] **Step 5: Commit**

```bash
git add README.md CLAUDE.md && git commit -m "Document launch-on-play and the Settings window"
```

---

## Final verification

- [ ] **Full suites green**

```bash
cd /Users/olli/git/beamhook && xcodegen generate && xcodebuild test -project Beamhook.xcodeproj -scheme BeamhookKit -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO && xcodebuild test -project Beamhook.xcodeproj -scheme Beamhook -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

- [ ] **End-to-end**: quit Spotify → press play → it launches and plays, focus stays put; toggle the setting off in Settings → the same press does nothing; hook Safari and quit it → macOS still handles play/pause.
