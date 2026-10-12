import XCTest
@testable import BeamhookKit

final class HeadphoneControlPreferenceTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let suite = "HeadphoneControlPreferenceTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    func testDefaultsToEnabledWhenUnset() {
        XCTAssertTrue(HeadphoneControlPreference.isEnabled(makeDefaults()))
    }

    func testRespectsAnExplicitOff() {
        let defaults = makeDefaults()
        HeadphoneControlPreference.setEnabled(false, in: defaults)
        XCTAssertFalse(HeadphoneControlPreference.isEnabled(defaults))
    }

    func testRespectsAnExplicitOn() {
        let defaults = makeDefaults()
        HeadphoneControlPreference.setEnabled(false, in: defaults)
        HeadphoneControlPreference.setEnabled(true, in: defaults)
        XCTAssertTrue(HeadphoneControlPreference.isEnabled(defaults))
    }
}

final class HeadphoneCommandTests: XCTestCase {
    func testToggleAndTrackCommandsIgnorePlayState() {
        for playing in [true, false, nil] as [Bool?] {
            XCTAssertEqual(HeadphoneCommand.togglePlayPause.key(targetPlaying: playing), .playPause)
            XCTAssertEqual(HeadphoneCommand.next.key(targetPlaying: playing), .next)
            XCTAssertEqual(HeadphoneCommand.previous.key(targetPlaying: playing), .previous)
        }
    }

    func testPlayTogglesOnlyWhenNotAlreadyPlaying() {
        XCTAssertEqual(HeadphoneCommand.play.key(targetPlaying: false), .playPause)
        XCTAssertNil(HeadphoneCommand.play.key(targetPlaying: true))
        // Unknown: a play request is the user asking for sound, so try.
        XCTAssertEqual(HeadphoneCommand.play.key(targetPlaying: nil), .playPause)
    }

    func testPauseTogglesOnlyWhenKnownPlaying() {
        XCTAssertEqual(HeadphoneCommand.pause.key(targetPlaying: true), .playPause)
        XCTAssertNil(HeadphoneCommand.pause.key(targetPlaying: false))
        // Unknown: an AirPod leaving the ear must never start playback.
        XCTAssertNil(HeadphoneCommand.pause.key(targetPlaying: nil))
    }

    func testOnlyExplicitPlayAndPauseNeedTheState() {
        XCTAssertTrue(HeadphoneCommand.play.needsPlayState)
        XCTAssertTrue(HeadphoneCommand.pause.needsPlayState)
        XCTAssertFalse(HeadphoneCommand.togglePlayPause.needsPlayState)
        XCTAssertFalse(HeadphoneCommand.next.needsPlayState)
        XCTAssertFalse(HeadphoneCommand.previous.needsPlayState)
    }
}

final class NowPlayingClaimDecisionTests: XCTestCase {
    func testClaimsOnlyWhenEnabledHookedAndRouting() {
        XCTAssertTrue(NowPlayingClaimDecision.shouldClaim(enabled: true, hasTarget: true, transportHijacked: true))
        XCTAssertFalse(NowPlayingClaimDecision.shouldClaim(enabled: false, hasTarget: true, transportHijacked: true))
        XCTAssertFalse(NowPlayingClaimDecision.shouldClaim(enabled: true, hasTarget: false, transportHijacked: true))
        // Browser hooked without tab control: the keyboard keys go to macOS,
        // so the headphones must too.
        XCTAssertFalse(NowPlayingClaimDecision.shouldClaim(enabled: true, hasTarget: true, transportHijacked: false))
    }
}
