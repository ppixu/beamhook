import XCTest
@testable import BeamhookKit

final class LaunchOnPlayPreferenceTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let suite = "LaunchOnPlayPreferenceTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    /// Absent means ON: a quit target's play/pause does nothing today, so
    /// launching is the better default.
    func testDefaultsToEnabledWhenUnset() {
        XCTAssertTrue(LaunchOnPlayPreference.isEnabled(makeDefaults()))
    }

    func testRespectsAnExplicitOff() {
        let defaults = makeDefaults()
        LaunchOnPlayPreference.setEnabled(false, in: defaults)
        XCTAssertFalse(LaunchOnPlayPreference.isEnabled(defaults))
    }

    func testRespectsAnExplicitOn() {
        let defaults = makeDefaults()
        LaunchOnPlayPreference.setEnabled(false, in: defaults)
        LaunchOnPlayPreference.setEnabled(true, in: defaults)
        XCTAssertTrue(LaunchOnPlayPreference.isEnabled(defaults))
    }
}
