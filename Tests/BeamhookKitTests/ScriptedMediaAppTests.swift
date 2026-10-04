import XCTest
@testable import BeamhookKit

final class ScriptedMediaAppTests: XCTestCase {
    func testDeniedMusicCommandReportsFailureThenRecoversAfterGrant() {
        let executor = MockScriptExecutor()
        let presence = MockPresence()
        presence.runningBundleIDs = [BuiltInApps.music.bundleID]
        let app = ScriptedMediaApp(definition: BuiltInApps.music, executor: executor, presence: presence)
        executor.succeed = false
        executor.cannedOutput = "playing"
        XCTAssertFalse(app.perform(.playPause))
        XCTAssertNil(app.isPlaying())
        executor.succeed = true
        XCTAssertTrue(app.perform(.playPause))
        XCTAssertEqual(app.isPlaying(), true)
    }

    private func makeVLC(executor: MockScriptExecutor, presence: MockPresence) -> ScriptedMediaApp {
        ScriptedMediaApp(definition: BuiltInApps.vlc, executor: executor, presence: presence)
    }

    func testPerformRunsScriptWhenRunning() {
        let exec = MockScriptExecutor()
        let presence = MockPresence()
        presence.runningBundleIDs = ["org.videolan.vlc"]
        let app = makeVLC(executor: exec, presence: presence)

        app.perform(.playPause)
        XCTAssertEqual(exec.ranScripts, ["tell application \"VLC\" to play"])
    }

    func testPerformDoesNothingWhenNotRunning() {
        let exec = MockScriptExecutor()
        let app = makeVLC(executor: exec, presence: MockPresence()) // nothing running
        app.perform(.playPause)
        XCTAssertTrue(exec.ranScripts.isEmpty)
    }

    func testPerformDoesNothingWhenRunningButNotReady() {
        // Running but still launching — scripting it is what wedged the app before.
        let exec = MockScriptExecutor()
        let presence = MockPresence()
        presence.runningBundleIDs = ["org.videolan.vlc"]
        presence.readyBundleIDs = []   // not finished launching
        let app = makeVLC(executor: exec, presence: presence)

        app.perform(.playPause)
        XCTAssertTrue(exec.ranScripts.isEmpty)
    }

    func testVolumeAndPlayStateSkippedWhenNotReady() {
        let exec = MockScriptExecutor()
        exec.cannedOutput = "256"
        let presence = MockPresence()
        presence.runningBundleIDs = ["org.videolan.vlc"]
        presence.readyBundleIDs = []   // running, not ready
        let app = makeVLC(executor: exec, presence: presence)

        XCTAssertNil(app.currentVolume())
        app.setVolume(50)
        XCTAssertTrue(exec.ranScripts.isEmpty)
    }

    func testCurrentVolumeParsesAndScales() {
        let exec = MockScriptExecutor()
        exec.cannedOutput = "256"           // VLC raw, max 512
        let presence = MockPresence()
        presence.runningBundleIDs = ["org.videolan.vlc"]
        let app = makeVLC(executor: exec, presence: presence)

        XCTAssertEqual(app.currentVolume(), 50)
    }

    func testSetVolumeSubstitutesScaledRawValue() {
        let exec = MockScriptExecutor()
        let presence = MockPresence()
        presence.runningBundleIDs = ["org.videolan.vlc"]
        let app = makeVLC(executor: exec, presence: presence)

        app.setVolume(50)
        XCTAssertEqual(exec.ranScripts, ["tell application \"VLC\" to set audio volume to 256"])
    }

    func testSupportsVolumeFalseWhenKindNone() {
        let def = AppDefinition(id: "x", displayName: "X", bundleID: "com.example.x", isBuiltIn: false,
                                playPauseScript: "x", nextScript: nil, previousScript: nil,
                                volumeScaleKind: .none, volumeGetScript: nil, volumeSetScript: nil)
        let app = ScriptedMediaApp(definition: def, executor: MockScriptExecutor(), presence: MockPresence())
        XCTAssertFalse(app.supportsVolume)
        XCTAssertNil(app.currentVolume())
    }

    func testCurrentVolumeReturnsNilWhenScriptFails() {
        let exec = MockScriptExecutor()
        exec.succeed = false
        exec.cannedOutput = "256"   // output present but result failed
        let presence = MockPresence()
        presence.runningBundleIDs = ["org.videolan.vlc"]
        let app = makeVLC(executor: exec, presence: presence)
        XCTAssertNil(app.currentVolume())
    }

    func testCurrentVolumeRejectsNonFiniteScriptOutput() {
        let presence = MockPresence()
        presence.runningBundleIDs = ["org.videolan.vlc"]

        for output in ["nan", "inf", "-inf"] {
            let exec = MockScriptExecutor()
            exec.cannedOutput = output
            let app = makeVLC(executor: exec, presence: presence)
            XCTAssertNil(app.currentVolume(), "output: \(output)")
        }
    }

    private func makeSpotify(executor: MockScriptExecutor, presence: MockPresence) -> ScriptedMediaApp {
        ScriptedMediaApp(definition: BuiltInApps.spotify, executor: executor, presence: presence)
    }

    func testIsPlayingTrueWhenOutputPlaying() {
        let exec = MockScriptExecutor()
        exec.cannedOutput = "playing"
        let presence = MockPresence()
        presence.runningBundleIDs = ["com.spotify.client"]
        let app = makeSpotify(executor: exec, presence: presence)
        XCTAssertEqual(app.isPlaying(), true)
    }

    func testIsPlayingFalseWhenOutputPaused() {
        let exec = MockScriptExecutor()
        exec.cannedOutput = "paused"
        let presence = MockPresence()
        presence.runningBundleIDs = ["com.spotify.client"]
        let app = makeSpotify(executor: exec, presence: presence)
        XCTAssertEqual(app.isPlaying(), false)
    }

    func testIsPlayingFalseWhenOutputStopped() {
        let exec = MockScriptExecutor()
        exec.cannedOutput = "stopped"
        let presence = MockPresence()
        presence.runningBundleIDs = ["com.spotify.client"]
        let app = makeSpotify(executor: exec, presence: presence)
        XCTAssertEqual(app.isPlaying(), false)
    }

    func testIsPlayingNilWhenNotRunning() {
        let exec = MockScriptExecutor()
        exec.cannedOutput = "playing"
        let app = makeSpotify(executor: exec, presence: MockPresence()) // nothing running
        XCTAssertNil(app.isPlaying())
    }

    func testIsPlayingNilWhenNoPlayStateScript() {
        let exec = MockScriptExecutor()
        exec.cannedOutput = "playing"
        let presence = MockPresence()
        presence.runningBundleIDs = ["com.coppertino.Vox"]
        let app = ScriptedMediaApp(definition: BuiltInApps.vox, executor: exec, presence: presence)
        XCTAssertNil(app.isPlaying())
    }

    func testPerformDispatchesCorrectScript() {
        let cases: [(MediaCommand, String)] = [
            (.playPause, "tell application \"VLC\" to play"),
            (.next,      "tell application \"VLC\" to next"),
            (.previous,  "tell application \"VLC\" to previous"),
        ]
        for (cmd, expected) in cases {
            let exec = MockScriptExecutor()
            let presence = MockPresence()
            presence.runningBundleIDs = ["org.videolan.vlc"]
            let app = makeVLC(executor: exec, presence: presence)
            app.perform(cmd)
            XCTAssertEqual(exec.ranScripts, [expected], "command: \(cmd)")
        }
    }

    // MARK: - Seeking

    private func seekingApp(kindScript: String? = "KIND", seekScript: String? = "SEEK {seconds}",
                            output: String? = nil, succeed: Bool = true)
        -> (ScriptedMediaApp, MockScriptExecutor) {
        let executor = MockScriptExecutor()
        executor.cannedOutput = output
        executor.succeed = succeed
        let presence = MockPresence()
        presence.runningBundleIDs = ["com.example.seek"]
        let definition = AppDefinition(
            id: "seek", displayName: "Seek", bundleID: "com.example.seek", isBuiltIn: false,
            playPauseScript: "PP", nextScript: "NEXT", previousScript: "PREV",
            volumeScaleKind: .none, volumeGetScript: nil, volumeSetScript: nil,
            playbackKindScript: kindScript, seekScript: seekScript)
        return (ScriptedMediaApp(definition: definition, executor: executor, presence: presence), executor)
    }

    func testPlaybackKindParsesTheScriptsAnswer() {
        XCTAssertEqual(seekingApp(output: "podcast").0.playbackKind(), .podcast)
        XCTAssertEqual(seekingApp(output: " music\n").0.playbackKind(), .music)
        XCTAssertEqual(seekingApp(output: "garbage").0.playbackKind(), .unknown)
        XCTAssertEqual(seekingApp(output: "podcast", succeed: false).0.playbackKind(), .unknown)
        XCTAssertEqual(seekingApp(kindScript: nil).0.playbackKind(), .music)
    }

    func testSeekSubstitutesSignedSeconds() {
        let (app, executor) = seekingApp()
        XCTAssertTrue(app.seek(by: -15))
        XCTAssertEqual(executor.ranScripts.last, "SEEK -15")
    }

    func testNoSeekScriptMeansNoSeeking() {
        let (app, executor) = seekingApp(seekScript: nil)
        XCTAssertFalse(app.canSeek)
        XCTAssertFalse(app.seek(by: 15))
        XCTAssertTrue(executor.ranScripts.isEmpty)
    }

    func testSpotifyReportsEpisodesAsPodcasts() {
        let spotify = BuiltInApps.spotify
        XCTAssertTrue(spotify.playbackKindScript?.contains("spotify:episode:") == true)
        XCTAssertTrue(spotify.seekScript?.contains("{seconds}") == true)
        XCTAssertFalse(spotify.seekScript?.contains("as text") == true)
        XCTAssertNotNil(BuiltInApps.music.seekScript)
        XCTAssertNotNil(BuiltInApps.vlc.seekScript)
    }
}
