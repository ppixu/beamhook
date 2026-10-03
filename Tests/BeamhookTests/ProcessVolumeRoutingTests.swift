import XCTest
import BeamhookKit
@testable import Beamhook

@MainActor
final class ProcessVolumeRoutingTests: XCTestCase {
    func testFallbackPreservesNativeVolumeAndSupportsBrowserParents() throws {
        guard #available(macOS 14.2, *) else { throw XCTSkip("Process taps require macOS 14.2") }
        let state = AppState()
        state.perAppMuteEnabled = true
        XCTAssertTrue(state.usesProcessVolume(bundleID: "com.example.unscriptable"))
        XCTAssertTrue(state.canControlVolume(bundleID: "com.example.unscriptable"))
        XCTAssertFalse(state.usesProcessVolume(bundleID: "com.spotify.client"))
        XCTAssertTrue(state.canControlVolume(bundleID: "com.spotify.client"))
        XCTAssertTrue(state.usesProcessVolume(bundleID: "com.apple.Safari"))
        XCTAssertTrue(state.usesProcessVolume(bundleID: "com.google.Chrome"))
        state.perAppMuteEnabled = false
        XCTAssertFalse(state.usesProcessVolume(bundleID: "com.example.unscriptable"))
        XCTAssertFalse(state.canControlVolume(bundleID: "com.example.unscriptable"))
        XCTAssertTrue(state.canControlVolume(bundleID: "com.spotify.client"))
    }

    func testBrowserAppRowsHaveVolumeWithoutTabScanAndDoNotUseTabCache() throws {
        guard #available(macOS 14.2, *) else { throw XCTSkip("Process taps require macOS 14.2") }
        let state = AppState()
        state.perAppMuteEnabled = true
        for bundleID in ["com.apple.Safari", "com.brave.Browser"] {
            XCTAssertTrue(state.usesProcessVolume(bundleID: bundleID))
            XCTAssertTrue(state.canControlVolume(bundleID: bundleID))
            let level = try XCTUnwrap(state.currentVolume(of: .app(bundleID: bundleID)))
            // A hooked/tab command can populate this cache; it must never change
            // what the parent reports as the browser-wide gain.
            state.volumeByBundle[bundleID] = level == 31 ? 32 : 31
            XCTAssertEqual(state.currentVolume(of: .app(bundleID: bundleID)), level)
        }
        XCTAssertNil(state.currentVolume(of: .browserTab(id: "missing-tab")),
                     "A missing tab must not fall back to adjusting the entire browser")
        state.perAppMuteEnabled = false
        for bundleID in ["com.apple.Safari", "com.brave.Browser"] {
            XCTAssertFalse(state.canControlVolume(bundleID: bundleID))
            XCTAssertNil(state.currentVolume(of: .app(bundleID: bundleID)))
        }
    }

    func testHookedBrowserTabKeepsItsOwnVolumeEvenWhenParentUsesProcessGain() throws {
        guard #available(macOS 14.2, *) else { throw XCTSkip("Process taps require macOS 14.2") }
        let state = AppState()
        state.perAppMuteEnabled = true
        state.selectedTargetID = "safari-youtube"
        var tab = BrowserMediaCandidate(browser: .safari, sourceID: "test-tab", windowIndex: 1,
                                        tabIndex: 1, title: "Test", artist: "", host: "example.com",
                                        isPlaying: true, isSelected: true, supportsTransport: true, volume: 37)
        state.browserMediaCandidates = [tab]
        state.selectedBrowserMediaID = tab.id
        XCTAssertEqual(state.currentVolume(of: .hookedTarget), 37)
        XCTAssertEqual(state.currentVolume(of: .browserTab(id: tab.id)), 37)
        tab.volume = nil
        state.browserMediaCandidates = [tab]
        XCTAssertNil(state.currentVolume(of: .hookedTarget), "A selected tab without volume must not become browser-wide control")
        state.perAppMuteEnabled = false
        tab.volume = 62
        state.browserMediaCandidates = [tab]
        XCTAssertEqual(state.currentVolume(of: .hookedTarget), 62, "Tab control is independent of process capture")
    }

    func testTransportIndicatorsRequirePlaybackControls() {
        let state = AppState()
        XCTAssertFalse(state.canPlayPauseVolumeSource(.app(bundleID: "com.example.sound-only")))
        XCTAssertTrue(state.canPlayPauseVolumeSource(.app(bundleID: "com.spotify.client")))
        for definition in state.availableApps where definition.menuControl != nil {
            XCTAssertTrue(state.canPlayPauseVolumeSource(.app(bundleID: definition.bundleID)))
        }
        XCTAssertFalse(state.canPlayPauseVolumeSource(.app(bundleID: "com.apple.Safari")))
        XCTAssertFalse(state.canPlayPauseVolumeSource(.browserTab(id: "missing")))
        let call = BrowserMediaCandidate(browser: .safari, sourceID: "call", windowIndex: 1,
                                        tabIndex: 1, title: "Call", artist: "", host: "example.com",
                                        isPlaying: true, isSelected: true, supportsTransport: false, volume: 50)
        state.activeBrowserMediaCandidates = [call]
        XCTAssertFalse(state.canPlayPauseVolumeSource(.browserTab(id: call.id)))
        XCTAssertFalse(state.canPlayPauseVolumeSource(.app(bundleID: "com.apple.Safari")))
        let media = BrowserMediaCandidate(browser: .safari, sourceID: "media", windowIndex: 1,
                                         tabIndex: 2, title: "Media", artist: "", host: "example.com",
                                         isPlaying: false, isSelected: true, supportsTransport: true, volume: 50)
        state.activeBrowserMediaCandidates = [media]
        XCTAssertTrue(state.canPlayPauseVolumeSource(.browserTab(id: media.id)))
        XCTAssertFalse(state.canPlayPauseVolumeSource(.app(bundleID: "com.apple.Safari")),
                       "Browser parents must not imply playback control over all tabs")
    }

}
