import XCTest
@testable import BeamhookKit

/// ⌘ flips which volume the hardware keys control, in both directions.
final class CommandVolumeRoutingTests: XCTestCase {
    private func destination(command: Bool,
                             hijacked: Bool,
                             enabled: Bool = true,
                             canTakeVolume: Bool = true) -> VolumeKeyDestination {
        VolumeKeyRouting.destination(commandHeld: command,
                                     hijacked: hijacked,
                                     commandRoutingEnabled: enabled,
                                     targetCanTakeVolume: canTakeVolume)
    }

    // MARK: - Plain keys keep their meaning

    func testPlainKeysReachTheSystemWhenTheAppIsNotHooked() {
        XCTAssertEqual(destination(command: false, hijacked: false), .system)
    }

    func testPlainKeysReachTheAppWhenHooked() {
        XCTAssertEqual(destination(command: false, hijacked: true), .app)
    }

    // MARK: - ⌘ leads to the other one

    func testCommandReachesTheAppWhenTheKeysAreNotHooked() {
        XCTAssertEqual(destination(command: true, hijacked: false), .app)
    }

    func testCommandEscapesToTheSystemWhenTheKeysAreHooked() {
        XCTAssertEqual(destination(command: true, hijacked: true), .system)
    }

    func testDisablingCommandRoutingLeavesTheChordToTheSystem() {
        XCTAssertEqual(destination(command: true, hijacked: false, enabled: false), .system)
    }

    /// Turning the setting off must never cost someone the way out of a hijack.
    func testDisablingCommandRoutingKeepsTheEscapeHatchOutOfAHijack() {
        XCTAssertEqual(destination(command: true, hijacked: true, enabled: false), .system)
    }

    // MARK: - A target that can't take the key never swallows it

    func testEveryPressReachesTheSystemWhenTheTargetCannotTakeVolume() {
        for command in [true, false] {
            for hijacked in [true, false] {
                XCTAssertEqual(
                    destination(command: command, hijacked: hijacked, canTakeVolume: false),
                    .system,
                    "command=\(command) hijacked=\(hijacked) must fall back to the system")
            }
        }
    }

    // MARK: - The hint names whichever side ⌘ reaches

    func testHintPointsAtTheSystemWhileTheKeysAreHooked() {
        XCTAssertEqual(VolumeKeyRouting.commandHintDestination(
            hijacked: true, commandRoutingEnabled: true, targetCanTakeVolume: true), .system)
    }

    func testHintPointsAtTheAppWhileTheKeysAreNotHooked() {
        XCTAssertEqual(VolumeKeyRouting.commandHintDestination(
            hijacked: false, commandRoutingEnabled: true, targetCanTakeVolume: true), .app)
    }

    func testHintIsHiddenWhenCommandChangesNothing() {
        XCTAssertNil(VolumeKeyRouting.commandHintDestination(
            hijacked: false, commandRoutingEnabled: false, targetCanTakeVolume: true))
        XCTAssertNil(VolumeKeyRouting.commandHintDestination(
            hijacked: true, commandRoutingEnabled: true, targetCanTakeVolume: false))
    }

    // MARK: - Preference

    private func makeDefaults() -> UserDefaults {
        let suite = "CommandVolumeRoutingTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    func testCommandRoutingIsOnByDefault() {
        XCTAssertTrue(CommandVolumePreference.isEnabled(makeDefaults()))
    }

    func testCommandRoutingRoundTrips() {
        let defaults = makeDefaults()
        CommandVolumePreference.setEnabled(false, in: defaults)
        XCTAssertFalse(CommandVolumePreference.isEnabled(defaults))
        CommandVolumePreference.setEnabled(true, in: defaults)
        XCTAssertTrue(CommandVolumePreference.isEnabled(defaults))
    }
}
