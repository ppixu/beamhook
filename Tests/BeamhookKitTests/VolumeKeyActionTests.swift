import XCTest
@testable import BeamhookKit

final class VolumeKeyActionTests: XCTestCase {
    private func resolve(_ key: MediaKey, command: Bool = false, hijacked: Bool = false,
                         targetHasVolume: Bool = true, session: Bool = false) -> VolumeKeyAction {
        VolumeKeyAction.resolve(key: key, commandHeld: command, hijacked: hijacked,
                                targetHasVolume: targetHasVolume, sessionActive: session)
    }

    // Hook ON: plain volume is the app, ⌘ is today's escape hatch to the system.
    func testHookOnPlainVolumeIsHandled() {
        XCTAssertEqual(resolve(.volumeUp, hijacked: true), .handle)
        XCTAssertEqual(resolve(.volumeDown, hijacked: true), .handle)
    }

    func testHookOnCommandVolumeGoesToSystemWithoutCommand() {
        XCTAssertEqual(resolve(.volumeUp, command: true, hijacked: true), .passThroughWithoutCommand)
    }

    // Hook OFF: ⌘ flips it — the app gets ⌘+volume.
    func testHookOffPlainVolumePassesThrough() {
        XCTAssertEqual(resolve(.volumeUp), .passThrough)
    }

    func testHookOffCommandVolumeIsHandled() {
        XCTAssertEqual(resolve(.volumeDown, command: true), .handle)
    }

    func testHookOffCommandVolumePassesThroughWhenTargetHasNoVolume() {
        XCTAssertEqual(resolve(.volumeUp, command: true, targetHasVolume: false), .passThrough)
    }

    // Mute: plain mute is always the system's.
    func testPlainMuteAlwaysPassesThrough() {
        XCTAssertEqual(resolve(.mute), .passThrough)
        XCTAssertEqual(resolve(.mute, hijacked: true), .passThrough)
        XCTAssertEqual(resolve(.mute, session: true), .passThrough)
    }

    func testCommandMuteIsHandledWhenTargetHasVolume() {
        XCTAssertEqual(resolve(.mute, command: true), .handle)
        XCTAssertEqual(resolve(.mute, command: true, hijacked: true), .handle)
    }

    func testCommandMutePassesThroughWhenTargetHasNoVolume() {
        XCTAssertEqual(resolve(.mute, command: true, targetHasVolume: false), .passThrough)
    }

    // Session: every volume key follows the picked source.
    func testSessionHandlesVolumeWithAndWithoutCommand() {
        XCTAssertEqual(resolve(.volumeUp, session: true), .handle)
        XCTAssertEqual(resolve(.volumeUp, command: true, hijacked: true, session: true), .handle)
        XCTAssertEqual(resolve(.volumeDown, command: true, targetHasVolume: false, session: true), .handle)
    }

    func testSessionHandlesCommandMuteEvenWithoutTargetVolume() {
        XCTAssertEqual(resolve(.mute, command: true, targetHasVolume: false, session: true), .handle)
    }

    func testOtherKeysPassThrough() {
        XCTAssertEqual(resolve(.playPause, command: true, hijacked: true, session: true), .passThrough)
        XCTAssertEqual(resolve(.fastForward, command: true, session: true), .passThrough)
    }
}
