import XCTest
@testable import BeamhookKit

final class BrowserPlaybackKindTests: XCTestCase {
    private func facts(_ host: String, duration: Double? = 300, list: Bool = false,
                       next: BrowserPlaybackFacts.NextButton = .enabled,
                       live: Bool = false) -> BrowserPlaybackFacts {
        BrowserPlaybackFacts(host: host, duration: duration, hasListParam: list,
                             nextButton: next, live: live)
    }

    func testYouTubePlaylistIsATracklistEvenWhenLong() {
        XCTAssertEqual(BrowserPlaybackKind.classify(facts("youtube.com", duration: 5000, list: true)), .tracklist)
    }

    func testLongYouTubeVideoIsAPodcast() {
        XCTAssertEqual(BrowserPlaybackKind.classify(facts("youtube.com", duration: 1200)), .podcast)
    }

    func testShortYouTubeVideoKeepsNext() {
        XCTAssertEqual(BrowserPlaybackKind.classify(facts("m.youtube.com", duration: 240)), .music)
    }

    func testBandcampAlbumWithEnabledNextIsATracklist() {
        XCTAssertEqual(BrowserPlaybackKind.classify(facts("artist.bandcamp.com", duration: 200)), .tracklist)
    }

    func testBandcampSingleTrackSkips() {
        XCTAssertEqual(BrowserPlaybackKind.classify(facts("artist.bandcamp.com", duration: 200, next: .disabled)), .podcast)
    }

    func testPageWithoutANextButtonSkips() {
        XCTAssertEqual(BrowserPlaybackKind.classify(facts("example.com", duration: 90, next: .absent)), .podcast)
    }

    func testLiveStreamsNeverSeek() {
        let live = facts("youtube.com", duration: nil, next: .absent, live: true)
        XCTAssertEqual(BrowserPlaybackKind.classify(live), .music)
        XCTAssertFalse(BrowserPlaybackKind.canSeek(live))
    }

    func testCanSeekNeedsAFiniteDuration() {
        XCTAssertTrue(BrowserPlaybackKind.canSeek(facts("example.com", duration: 60)))
        XCTAssertFalse(BrowserPlaybackKind.canSeek(facts("example.com", duration: nil)))
    }

    func testYouTubeSkipsTenSecondsElsewhereFifteen() {
        XCTAssertEqual(BrowserPlaybackKind.skipSeconds(host: "youtube.com"), SkipSeconds(forward: 10, back: 10))
        XCTAssertEqual(BrowserPlaybackKind.skipSeconds(host: "music.youtube.com"), SkipSeconds(forward: 10, back: 10))
        XCTAssertEqual(BrowserPlaybackKind.skipSeconds(host: "example.com"), .standard)
    }

    func testFactsDecodeFromThePagesJSON() throws {
        let json = #"{"host":"youtube.com","duration":null,"hasListParam":true,"nextButton":"absent","live":false}"#
        let decoded = try JSONDecoder().decode(BrowserPlaybackFacts.self, from: Data(json.utf8))
        XCTAssertEqual(decoded, facts("youtube.com", duration: nil, list: true, next: .absent))
    }
}
