import XCTest
@testable import BeamhookKit

final class PerAppMutePreferenceTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let suite = "PerAppMutePreferenceTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    /// Absent means ON: the mute buttons are the menu's whole answer for apps
    /// Beamhook can't otherwise control, so they are there from the start (the
    /// permission behind them is asked for once, at first launch).
    func testDefaultsToEnabledWhenUnset() {
        XCTAssertTrue(PerAppMutePreference.isEnabled(makeDefaults()))
    }

    func testRespectsAnExplicitOff() {
        let defaults = makeDefaults()
        PerAppMutePreference.setEnabled(false, in: defaults)
        XCTAssertFalse(PerAppMutePreference.isEnabled(defaults))
    }

    func testRespectsAnExplicitOn() {
        let defaults = makeDefaults()
        PerAppMutePreference.setEnabled(false, in: defaults)
        PerAppMutePreference.setEnabled(true, in: defaults)
        XCTAssertTrue(PerAppMutePreference.isEnabled(defaults))
    }

    func testMutedAppsDefaultToEmpty() {
        XCTAssertTrue(PerAppMutePreference.mutedBundleIDs(makeDefaults()).isEmpty)
    }

    func testMutedAppsRoundTrip() {
        let defaults = makeDefaults()
        let ids: Set<String> = ["com.anthropic.claudefordesktop", "com.openai.codex"]
        PerAppMutePreference.setMutedBundleIDs(ids, in: defaults)
        XCTAssertEqual(PerAppMutePreference.mutedBundleIDs(defaults), ids)
    }

    func testReplacingTheMutedSetDropsOldEntries() {
        let defaults = makeDefaults()
        PerAppMutePreference.setMutedBundleIDs(["a", "b"], in: defaults)
        PerAppMutePreference.setMutedBundleIDs(["b"], in: defaults)
        XCTAssertEqual(PerAppMutePreference.mutedBundleIDs(defaults), ["b"])
    }

    /// Turning the feature off is a clean slate: a mute set that silently
    /// survived a month of the feature being disabled would come back as a
    /// surprise, not a convenience.
    func testDisablingClearsTheMutedSet() {
        let defaults = makeDefaults()
        PerAppMutePreference.setEnabled(true, in: defaults)
        PerAppMutePreference.setMutedBundleIDs(["com.openai.codex"], in: defaults)
        PerAppMutePreference.setEnabled(false, in: defaults)
        XCTAssertTrue(PerAppMutePreference.mutedBundleIDs(defaults).isEmpty)
        PerAppMutePreference.setEnabled(true, in: defaults)
        XCTAssertTrue(PerAppMutePreference.mutedBundleIDs(defaults).isEmpty)
    }
}
