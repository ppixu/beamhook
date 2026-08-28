import XCTest
@testable import Beamhook
import BeamhookKit

final class MediaKeyTapTests: XCTestCase {
    func testRoutingFlagsSupportConcurrentReadersAndWriters() {
        let tap = MediaKeyTap { _ in }

        DispatchQueue.concurrentPerform(iterations: 1_000) { index in
            if index.isMultiple(of: 2) {
                tap.transportKeysHijacked = index.isMultiple(of: 4)
                tap.volumeKeysHijacked = index.isMultiple(of: 6)
            } else {
                _ = tap.transportKeysHijacked
                _ = tap.volumeKeysHijacked
            }
        }

        tap.transportKeysHijacked = true
        tap.volumeKeysHijacked = false
        XCTAssertTrue(tap.transportKeysHijacked)
        XCTAssertFalse(tap.volumeKeysHijacked)
    }

    // MARK: - Passthrough notification

    /// A hardware media-key event as the tap's callback receives it.
    /// Layout matches MediaKeyTap.postNativePlayPause and ev_keymap.h.
    private func mediaKeyEvent(keyCode: Int,
                               isDown: Bool,
                               isRepeat: Bool = false,
                               command: Bool = false) -> CGEvent {
        let keyFlags = (isDown ? 0xA00 : 0xB00) | (isRepeat ? 0x1 : 0x0)
        let data1 = (keyCode << 16) | keyFlags
        let nsEvent = NSEvent.otherEvent(
            with: .systemDefined, location: .zero,
            modifierFlags: command ? [.command] : [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0, context: nil,
            subtype: Int16(MediaKeyDecoder.systemDefinedMediaKeysSubtype),
            data1: data1, data2: -1)!
        return nsEvent.cgEvent!
    }

    private let systemDefinedType = CGEventType(rawValue: 14)!

    private func drainMainQueue() {
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 1)
    }

    func testPassedThroughPlayPauseDownNotifiesAndKeepsTheEvent() {
        var passedThrough: [MediaKey] = []
        var handled: [MediaKey] = []
        let tap = MediaKeyTap(handler: { handled.append($0) },
                              passthroughHandler: { passedThrough.append($0) })
        tap.transportKeysHijacked = false

        let result = tap.handle(type: systemDefinedType,
                                event: mediaKeyEvent(keyCode: 16, isDown: true))

        XCTAssertNotNil(result, "a passed-through event must continue to macOS")
        drainMainQueue()
        XCTAssertEqual(passedThrough, [.playPause])
        XCTAssertTrue(handled.isEmpty, "a passed-through key is not routed to the target")
    }

    func testHijackedPlayPauseIsSwallowedWithoutPassthroughNotice() {
        var passedThrough: [MediaKey] = []
        var handled: [MediaKey] = []
        let tap = MediaKeyTap(handler: { handled.append($0) },
                              passthroughHandler: { passedThrough.append($0) })
        tap.transportKeysHijacked = true

        let result = tap.handle(type: systemDefinedType,
                                event: mediaKeyEvent(keyCode: 16, isDown: true))

        XCTAssertNil(result, "a hijacked transport key must be swallowed")
        drainMainQueue()
        XCTAssertEqual(handled, [.playPause])
        XCTAssertTrue(passedThrough.isEmpty)
    }

    // MARK: - Volume routing

    /// NX_KEYTYPE_SOUND_UP.
    private let volumeUpKeyCode = 0

    /// Volume-capable, running target: the precondition for either routing to
    /// swallow a key. Without it every press belongs to the system.
    private func volumeTap(hijacked: Bool,
                           commandRouting: Bool = true,
                           canTakeVolume: Bool = true) -> MediaKeyTap {
        let tap = MediaKeyTap { _ in }
        tap.volumeKeysHijacked = hijacked
        tap.commandVolumeRouting = commandRouting
        tap.targetCanTakeVolume = canTakeVolume
        return tap
    }

    func testCommandVolumeIsSwallowedForTheAppWhenTheKeysAreNotHooked() {
        var handled: [MediaKey] = []
        let tap = MediaKeyTap(handler: { handled.append($0) })
        tap.volumeKeysHijacked = false
        tap.commandVolumeRouting = true
        tap.targetCanTakeVolume = true

        let result = tap.handle(type: systemDefinedType,
                                event: mediaKeyEvent(keyCode: volumeUpKeyCode,
                                                     isDown: true, command: true))

        XCTAssertNil(result, "⌘ + volume must be swallowed and routed to the app")
        drainMainQueue()
        XCTAssertEqual(handled, [.volumeUp])
    }

    func testPlainVolumeStillReachesTheSystemWhenTheKeysAreNotHooked() {
        var handled: [MediaKey] = []
        let tap = MediaKeyTap(handler: { handled.append($0) })
        tap.volumeKeysHijacked = false
        tap.commandVolumeRouting = true
        tap.targetCanTakeVolume = true

        let result = tap.handle(type: systemDefinedType,
                                event: mediaKeyEvent(keyCode: volumeUpKeyCode, isDown: true))

        XCTAssertNotNil(result, "an unmodified volume key belongs to the system")
        drainMainQueue()
        XCTAssertTrue(handled.isEmpty)
    }

    func testCommandVolumeEscapesToTheSystemWithTheModifierStripped() {
        let tap = volumeTap(hijacked: true)

        let result = tap.handle(type: systemDefinedType,
                                event: mediaKeyEvent(keyCode: volumeUpKeyCode,
                                                     isDown: true, command: true))

        let passed = try? XCTUnwrap(result?.takeUnretainedValue())
        XCTAssertNotNil(passed)
        XCTAssertFalse(passed!.flags.contains(.maskCommand),
                       "macOS must receive an ordinary volume key, not a modified shortcut")
    }

    func testCommandVolumeIsLeftToTheSystemWhenTheSettingIsOff() {
        var handled: [MediaKey] = []
        let tap = MediaKeyTap(handler: { handled.append($0) })
        tap.volumeKeysHijacked = false
        tap.commandVolumeRouting = false
        tap.targetCanTakeVolume = true

        let result = tap.handle(type: systemDefinedType,
                                event: mediaKeyEvent(keyCode: volumeUpKeyCode,
                                                     isDown: true, command: true))

        XCTAssertNotNil(result)
        drainMainQueue()
        XCTAssertTrue(handled.isEmpty)
    }

    /// The hooked app isn't running: a swallowed press could only die silently,
    /// so the keys go back to macOS — hooked checkbox or not.
    func testVolumeKeysReachTheSystemWhenTheTargetCannotTakeThem() {
        for hijacked in [true, false] {
            for command in [true, false] {
                var handled: [MediaKey] = []
                let tap = MediaKeyTap(handler: { handled.append($0) })
                tap.volumeKeysHijacked = hijacked
                tap.commandVolumeRouting = true
                tap.targetCanTakeVolume = false

                let result = tap.handle(type: systemDefinedType,
                                        event: mediaKeyEvent(keyCode: volumeUpKeyCode,
                                                             isDown: true, command: command))

                XCTAssertNotNil(result, "hijacked=\(hijacked) command=\(command)")
                drainMainQueue()
                XCTAssertTrue(handled.isEmpty, "hijacked=\(hijacked) command=\(command)")
            }
        }
    }

    /// Holding the key must keep ramping, unlike transport keys which act once.
    func testHookedVolumeRepeatsAreForwarded() {
        var handled: [MediaKey] = []
        let tap = MediaKeyTap(handler: { handled.append($0) })
        tap.volumeKeysHijacked = true
        tap.targetCanTakeVolume = true

        let result = tap.handle(type: systemDefinedType,
                                event: mediaKeyEvent(keyCode: volumeUpKeyCode,
                                                     isDown: true, isRepeat: true))

        XCTAssertNil(result)
        drainMainQueue()
        XCTAssertEqual(handled, [.volumeUp])
    }

    func testPassedThroughKeyUpAndRepeatDoNotNotify() {
        var passedThrough: [MediaKey] = []
        let tap = MediaKeyTap(handler: { _ in },
                              passthroughHandler: { passedThrough.append($0) })
        tap.transportKeysHijacked = false

        let upResult = tap.handle(type: systemDefinedType,
                                  event: mediaKeyEvent(keyCode: 16, isDown: false))
        let repeatResult = tap.handle(type: systemDefinedType,
                                      event: mediaKeyEvent(keyCode: 16, isDown: true, isRepeat: true))

        XCTAssertNotNil(upResult)
        XCTAssertNotNil(repeatResult)
        drainMainQueue()
        XCTAssertTrue(passedThrough.isEmpty, "only a fresh key-down warrants a notice")
    }
}
