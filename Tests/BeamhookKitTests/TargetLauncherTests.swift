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

    /// An app that's already running AND ready needs no "Starting …" HUD — there's
    /// nothing to wait for, so announcing a launch would be misleading. Also covers
    /// a target whose `isReady` never flips true (`WorkspacePresenceChecker.isReady`
    /// documents that trade-off): without the guard, this same code path fires the
    /// announcement on every press before the eventual timeout.
    func testDoesNotAnnounceWhenAlreadyReady() async {
        let app = MockMediaApp(id: "spotify", isRunning: true)
        app.readyValue = true
        let launcher = MockAppLauncher()
        let sleeper = CountingSleeper()
        let subject = makeSubject(launcher: launcher, sleeper: sleeper)
        var startedCount = 0

        let outcome = await subject.launchAndPlay(app,
                                                  isStillHooked: { true },
                                                  onLaunchStarted: { startedCount += 1 })

        XCTAssertEqual(outcome, .played)
        XCTAssertEqual(startedCount, 0)
        XCTAssertEqual(sleeper.sleepCount, 0)
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
            // Clear this before re-entering: if the `isLaunching` single-flight
            // guard this test exercises ever regressed, the reentrant call below
            // would reach `launcher.launch` again and re-invoke `onLaunch` — an
            // unbounded recursion that hangs or crashes the test run instead of
            // failing it. Clearing here caps the recursion at one extra level, so
            // a regression instead shows up as a clean assertion failure.
            launcher.onLaunch = nil
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
