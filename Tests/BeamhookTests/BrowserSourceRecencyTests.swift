import XCTest
@testable import Beamhook

@MainActor
final class BrowserSourceRecencyTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    private func tab(_ id: String, playing: Bool = false, selected: Bool = false) -> BrowserMediaCandidate {
        BrowserMediaCandidate(browser: .safari, sourceID: id, windowIndex: 1,
                              tabIndex: 1, title: id, artist: "", host: "example.com",
                              isPlaying: playing, isSelected: selected,
                              supportsTransport: true, volume: 50)
    }

    func testPausedTabSurvivesUntilTwoHoursWithoutRefreshingItsExpiry() {
        let state = AppState()
        _ = state.recentBrowserSources(from: [tab("music", playing: true)], browser: .safari, now: start)
        let paused = tab("music")
        for elapsed in [60.0, 3_600, 7_199] {
            XCTAssertEqual(state.recentBrowserSources(from: [paused, tab("never-played")],
                browser: .safari, now: start.addingTimeInterval(elapsed)), [paused])
        }
        XCTAssertEqual(state.recentBrowserBundleIDs(now: start.addingTimeInterval(7_199)), ["com.apple.Safari"])
        XCTAssertTrue(state.recentBrowserSources(from: [paused], browser: .safari,
            now: start.addingTimeInterval(7_200)).isEmpty)
        XCTAssertTrue(state.recentBrowserBundleIDs(now: start.addingTimeInterval(7_200)).isEmpty)
    }

    func testContinuingAndResumedPlaybackRenewRetention() {
        let state = AppState()
        for elapsed in [0.0, 7_000, 8_000] {
            _ = state.recentBrowserSources(from: [tab("music", playing: true)], browser: .safari,
                                           now: start.addingTimeInterval(elapsed))
        }
        let paused = tab("music")
        XCTAssertEqual(state.recentBrowserSources(from: [paused], browser: .safari,
            now: start.addingTimeInterval(15_199)), [paused])
        XCTAssertTrue(state.recentBrowserSources(from: [paused], browser: .safari,
            now: start.addingTimeInterval(15_200)).isEmpty)
        XCTAssertEqual(state.recentBrowserSources(from: [tab("music", playing: true)], browser: .safari,
            now: start.addingTimeInterval(16_000)).count, 1)
    }

    func testClosedOrNavigatedTabIsForgotten() {
        let state = AppState()
        _ = state.recentBrowserSources(from: [tab("old-page", playing: true)], browser: .safari, now: start)
        XCTAssertTrue(state.recentBrowserSources(from: [tab("new-page")], browser: .safari,
            now: start.addingTimeInterval(10)).isEmpty)
        XCTAssertTrue(state.recentBrowserBundleIDs(now: start.addingTimeInterval(10)).isEmpty)
    }

    func testThreeRowLimitDoesNotEraseOtherRecentTabs() {
        let state = AppState()
        let playing = ["A", "B", "C", "D"].map { tab($0, playing: true) }
        XCTAssertEqual(state.recentBrowserSources(from: playing, browser: .safari, now: start).count, 3)
        let remaining = tab("D")
        XCTAssertEqual(state.recentBrowserSources(from: [remaining], browser: .safari,
            now: start.addingTimeInterval(10)), [remaining])
    }

    func testExplicitlySelectedTabRemainsAvailableWithoutPlaybackHistory() {
        let state = AppState()
        let selected = tab("hooked", selected: true)
        XCTAssertEqual(state.recentBrowserSources(from: [selected, tab("unplayed")], browser: .safari,
            now: start), [selected])
    }
    func testDiscoveryPrefersPlayingMediaAndSkipsCalls() {
        let paused = tab("video")
        let playing = tab("playing", playing: true)
        let call = BrowserMediaCandidate(browser: .safari, sourceID: "call", windowIndex: 1,
            tabIndex: 1, title: "Call", artist: "", host: "example.com", isPlaying: true,
            isSelected: false, supportsTransport: false, volume: 50)
        XCTAssertEqual(AppState.discoveredPlaybackCandidate([call, paused, playing]), playing)
        XCTAssertEqual(AppState.discoveredPlaybackCandidate([call, paused]), paused)
        XCTAssertNil(AppState.discoveredPlaybackCandidate([call]))
        XCTAssertNil(AppState.discoveredPlaybackCandidate([]))
    }

}
