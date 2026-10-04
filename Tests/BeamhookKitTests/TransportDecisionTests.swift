import XCTest
@testable import BeamhookKit

final class TransportDecisionTests: XCTestCase {
    private let skip = SkipSeconds(forward: 30, back: 10)

    private func decide(_ command: MediaCommand, _ kind: PlaybackKind, canSeek: Bool = true,
                        on: Bool = true, always: Bool = false) -> TransportAction {
        TransportDecision.decide(command: command, kind: kind, canSeek: canSeek, skip: skip,
                                 skipOnPodcasts: on, alwaysSkip: always)
    }

    func testPodcastSeeksByTheAppsOwnLengthsInEachDirection() {
        XCTAssertEqual(decide(.next, .podcast), .seek(seconds: 30))
        XCTAssertEqual(decide(.previous, .podcast), .seek(seconds: -10))
    }

    func testMusicAndTracklistChangeTrackUnlessAlwaysSkip() {
        for kind in [PlaybackKind.music, .tracklist] {
            XCTAssertEqual(decide(.next, kind), .track(.next))
            XCTAssertEqual(decide(.previous, kind), .track(.previous))
            XCTAssertEqual(decide(.next, kind, always: true), .seek(seconds: 30))
            XCTAssertEqual(decide(.previous, kind, always: true), .seek(seconds: -10))
        }
    }

    func testOffSettingAlwaysChangesTrackEvenWithAlwaysSkip() {
        XCTAssertEqual(decide(.next, .podcast, on: false), .track(.next))
        XCTAssertEqual(decide(.next, .music, on: false, always: true), .track(.next))
    }

    func testUnknownKindOrNoSeekingFallsBackToTrack() {
        XCTAssertEqual(decide(.next, .unknown, always: true), .track(.next))
        XCTAssertEqual(decide(.next, .podcast, canSeek: false), .track(.next))
    }

    func testPlayPauseIsNeverASeek() {
        XCTAssertEqual(decide(.playPause, .podcast, always: true), .track(.playPause))
    }

    func testPreferenceDefaultsAndRoundTrip() {
        let suite = "TrackKeyPreferenceTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertTrue(TrackKeyPreference.skipOnPodcasts(defaults))
        XCTAssertFalse(TrackKeyPreference.alwaysSkip(defaults))
        TrackKeyPreference.setSkipOnPodcasts(false, in: defaults)
        TrackKeyPreference.setAlwaysSkip(true, in: defaults)
        XCTAssertFalse(TrackKeyPreference.skipOnPodcasts(defaults))
        XCTAssertTrue(TrackKeyPreference.alwaysSkip(defaults))
        XCTAssertEqual(TrackKeyPreference.skipOnPodcastsKey, "skipOnPodcasts")
        XCTAssertEqual(TrackKeyPreference.alwaysSkipKey, "alwaysSkip")
    }
}
