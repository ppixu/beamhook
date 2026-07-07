import XCTest
@testable import BeamhookKit

final class ScriptedMediaAppTests: XCTestCase {
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
}
