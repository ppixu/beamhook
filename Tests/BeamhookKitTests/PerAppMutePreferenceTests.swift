import XCTest
@testable import BeamhookKit

final class PerAppMutePreferenceTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let suite = "PerAppMutePreferenceTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    /// Absent means OFF: muting rides on a system-audio tap, which costs a
    /// scary-sounding permission — nobody should hit that prompt uninvited.
    func testDefaultsToDisabledWhenUnset() {
        XCTAssertFalse(PerAppMutePreference.isEnabled(makeDefaults()))
    }

    func testRespectsAnExplicitOn() {
        let defaults = makeDefaults()
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
