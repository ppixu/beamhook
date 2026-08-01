import XCTest
@testable import BeamhookKit

final class PlayPauseHUDPreferenceTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let suite = "PlayPauseHUDPreferenceTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    /// Absent means ON: without the overlay a play/pause press is silent, so
    /// nothing confirms the key reached the hooked app.
    func testDefaultsToEnabledWhenUnset() {
        XCTAssertTrue(PlayPauseHUDPreference.isEnabled(makeDefaults()))
    }

    func testRespectsAnExplicitOff() {
        let defaults = makeDefaults()
        PlayPauseHUDPreference.setEnabled(false, in: defaults)
        XCTAssertFalse(PlayPauseHUDPreference.isEnabled(defaults))
    }

    func testRespectsAnExplicitOn() {
        let defaults = makeDefaults()
        PlayPauseHUDPreference.setEnabled(false, in: defaults)
        PlayPauseHUDPreference.setEnabled(true, in: defaults)
        XCTAssertTrue(PlayPauseHUDPreference.isEnabled(defaults))
    }

    /// Its key must not collide with the launch-on-play switch, which is stored
    /// in the same domain and defaults the same way.
    func testUsesItsOwnStorageKey() {
        XCTAssertNotEqual(PlayPauseHUDPreference.storageKey, LaunchOnPlayPreference.storageKey)
    }
}
