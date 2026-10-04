import XCTest
import BeamhookKit
@testable import Beamhook

@MainActor
final class MenuPlaybackDiscoveryTests: XCTestCase {
    func testPlayingHiddenPlayerEntersShortlistWithoutShowAllOrAudibleSamples() async {
        let state = AppState()
        let player = DiscoveryPlayer()
        let row = PlayingApp(id: player.bundleID, displayName: "VLC", bundleID: player.bundleID)
        state.setMenuVisible(true)
        XCTAssertFalse(state.showAllMenuApps)
        XCTAssertTrue(state.recentAppRows([row]).isEmpty)
        XCTAssertFalse(state.audibleApps.contains(player.bundleID))

        await state.refreshMenuPlayback(apps: [player])

        XCTAssertEqual(player.readCount, 1)
        XCTAssertEqual(state.recentAppRows([row]), [row])
        XCTAssertEqual(state.playbackHint(for: player.bundleID), true)
        player.playing = false
        await state.refreshMenuPlayback(apps: [player])
        XCTAssertEqual(state.recentAppRows([row]), [row], "A paused recent player keeps its resume control")
    }

    func testPausedAndUnreadablePlayersDoNotBecomeRecent() async {
        let state = AppState()
        state.setMenuVisible(true)
        let player = DiscoveryPlayer()
        let row = PlayingApp(id: player.bundleID, displayName: "VLC", bundleID: player.bundleID)
        player.playing = false
        await state.refreshMenuPlayback(apps: [player])
        XCTAssertTrue(state.recentAppRows([row]).isEmpty)
        player.playing = nil
        await state.refreshMenuPlayback(apps: [player])
        XCTAssertTrue(state.recentAppRows([row]).isEmpty)
    }

    func testDiscoveryDoesNotPollWithMenuClosedOrPlayerNotReady() async {
        let state = AppState()
        let player = DiscoveryPlayer()
        await state.refreshMenuPlayback(apps: [player])
        XCTAssertEqual(player.readCount, 0)
        state.setMenuVisible(true)
        player.isRunning = false
        await state.refreshMenuPlayback(apps: [player])
        XCTAssertEqual(player.readCount, 0)
    }

    func testBrowserPlaybackRemainsWithTabDiscovery() async {
        let state = AppState()
        state.setMenuVisible(true)
        let browser = DiscoveryPlayer(bundleID: "com.apple.Safari")
        await state.refreshMenuPlayback(apps: [browser])
        XCTAssertEqual(browser.readCount, 0)
    }
}

private final class DiscoveryPlayer: MediaApp, @unchecked Sendable {
    let id = "discovery-player"
    let displayName = "VLC"
    let bundleID: String
    var isRunning = true
    var playing: Bool? = true
    var readCount = 0
    init(bundleID: String = "com.beamhook.tests.hidden-vlc") { self.bundleID = bundleID }
    func perform(_ command: MediaCommand) -> Bool { true }
    var supportsVolume: Bool { true }
    func currentVolume() -> Int? { 0 }
    func setVolume(_ percent: Int) {}
    func isPlaying() -> Bool? { readCount += 1; return playing }
}
