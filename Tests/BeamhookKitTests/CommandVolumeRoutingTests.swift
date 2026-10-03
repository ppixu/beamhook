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

    // MARK: - Volume-source picker session

    /// Picker volume follows the selection, retaining Command as the system escape
    /// when plain volume keys are hooked.
    func testSessionRoutesVolumeExceptHookedCommandEscape() {
        for command in [true, false] {
            for hijacked in [true, false] {
                for enabled in [true, false] {
                    for targetCanTake in [true, false] {
                        XCTAssertEqual(
                            VolumeKeyRouting.destination(commandHeld: command,
                                                         hijacked: hijacked,
                                                         commandRoutingEnabled: enabled,
                                                         targetCanTakeVolume: targetCanTake,
                                                         sessionSourceCanTakeVolume: true),
                            command && hijacked ? .system : .app,
                            "command=\(command) hijacked=\(hijacked) enabled=\(enabled) target=\(targetCanTake)")
                    }
                }
            }
        }
    }

    /// A picked source that can't take the key (it quit, or the list is
    /// empty) never swallows it — not even when the hooked app could.
    func testSessionHandsEveryVolumeKeyToTheSystemWhenThePickedSourceCannotTakeIt() {
        for command in [true, false] {
            for hijacked in [true, false] {
                XCTAssertEqual(
                    VolumeKeyRouting.destination(commandHeld: command,
                                                 hijacked: hijacked,
                                                 commandRoutingEnabled: true,
                                                 targetCanTakeVolume: true,
                                                 sessionSourceCanTakeVolume: false),
                    .system,
                    "command=\(command) hijacked=\(hijacked)")
            }
        }
    }

    func testNoSessionLeavesTheFlipUntouched() {
        for command in [true, false] {
            for hijacked in [true, false] {
                XCTAssertEqual(
                    VolumeKeyRouting.destination(commandHeld: command,
                                                 hijacked: hijacked,
                                                 commandRoutingEnabled: true,
                                                 targetCanTakeVolume: true,
                                                 sessionSourceCanTakeVolume: nil),
                    destination(command: command, hijacked: hijacked))
            }
        }
    }

    private func mute(command: Bool,
                      hijacked: Bool,
                      enabled: Bool = true,
                      canTakeMute: Bool = true,
                      session: Bool? = nil) -> VolumeKeyDestination {
        VolumeKeyRouting.muteDestination(commandHeld: command,
                                         hijacked: hijacked,
                                         commandRoutingEnabled: enabled,
                                         targetCanTakeMute: canTakeMute,
                                         sessionSourceCanTakeMute: session)
    }

    /// Outside a session mute follows exactly the volume keys' flip, with
    /// mute's own capability.
    func testMuteOutsideASessionMatchesTheVolumeFlip() {
        for command in [true, false] {
            for hijacked in [true, false] {
                for enabled in [true, false] {
                    for canTake in [true, false] {
                        XCTAssertEqual(
                            mute(command: command, hijacked: hijacked,
                                 enabled: enabled, canTakeMute: canTake),
                            destination(command: command, hijacked: hijacked,
                                        enabled: enabled, canTakeVolume: canTake),
                            "command=\(command) hijacked=\(hijacked) enabled=\(enabled) canTake=\(canTake)")
                    }
                }
            }
        }
    }

    func testSessionCommandMuteTogglesThePickedSource() {
        XCTAssertEqual(mute(command: true, hijacked: true, session: true), .system)
        XCTAssertEqual(mute(command: true, hijacked: false, enabled: false,
                            canTakeMute: false, session: true), .app)
    }

    func testSessionCommandMuteReachesTheSystemWhenThePickedSourceCannotBeMuted() {
        XCTAssertEqual(mute(command: true, hijacked: false, session: false), .system)
    }

    /// Plain Mute with the hook off stays the system's, even in a session.
    func testSessionLeavesPlainMuteToTheSystemWithTheHookOff() {
        XCTAssertEqual(mute(command: false, hijacked: false, session: true), .system)
        XCTAssertEqual(mute(command: false, hijacked: false, session: false), .system)
    }

    /// With the hook on, plain Mute acts on the picked source in a session, so
    /// the picked source's capability decides — not the hooked app's.
    func testSessionGatesHookedPlainMuteOnThePickedSource() {
        XCTAssertEqual(mute(command: false, hijacked: true, canTakeMute: true, session: true), .app)
        // A picked tab with per-app mute off: the hooked app can't be muted,
        // but the tab can.
        XCTAssertEqual(mute(command: false, hijacked: true, canTakeMute: false, session: true), .app)
        // A picked app that quit while the hooked app still runs.
        XCTAssertEqual(mute(command: false, hijacked: true, canTakeMute: true, session: false), .system)
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
