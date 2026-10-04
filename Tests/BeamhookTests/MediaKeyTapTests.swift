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
                tap.volumeSessionActive = index.isMultiple(of: 8)
                tap.volumeSessionCanTakeMute = index.isMultiple(of: 10)
                tap.volumeSessionCanTakeVolume = index.isMultiple(of: 12)
            } else {
                _ = tap.transportKeysHijacked
                _ = tap.volumeKeysHijacked
                _ = tap.volumeSessionActive
                _ = tap.volumeSessionCanTakeMute
                _ = tap.volumeSessionCanTakeVolume
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

    func testBothTrackKeyPairsAreSwallowedAndRoutedOncePerPress() {
        for (code, key) in [(17, MediaKey.next), (18, .previous), (19, .fastForward), (20, .rewind)] {
            var handled: [MediaKey] = []
            var passed: [MediaKey] = []
            let tap = MediaKeyTap(handler: { handled.append($0) },
                                  passthroughHandler: { passed.append($0) })
            tap.transportKeysHijacked = true
            for (down, repeated) in [(true, false), (true, true), (false, false)] {
                let event = mediaKeyEvent(keyCode: code, isDown: down, isRepeat: repeated)
                XCTAssertNil(tap.handle(type: systemDefinedType, event: event), "code \(code) must not reach Spotify")
            }
            drainMainQueue()
            XCTAssertEqual(handled, [key])
            XCTAssertTrue(passed.isEmpty)
        }
    }

    func testAlternateTrackKeysPassThroughWhenUnhooked() {
        var handled: [MediaKey] = []
        let tap = MediaKeyTap(handler: { handled.append($0) })
        tap.transportKeysHijacked = false
        for code in [19, 20] {
            for (down, repeated) in [(true, false), (true, true), (false, false)] {
                let event = mediaKeyEvent(keyCode: code, isDown: down, isRepeat: repeated)
                XCTAssertNotNil(tap.handle(type: systemDefinedType, event: event))
            }
        }
        drainMainQueue()
        XCTAssertTrue(handled.isEmpty)
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

    func testCommandPlayTargetsPickerOnceEvenWhenHookedTransportPassesThrough() {
        var picked = 0
        let tap = MediaKeyTap(handler: { _ in XCTFail("Must not reach hooked target") },
                             passthroughHandler: { _ in XCTFail("Must not reach system") },
                             pickerPlayPauseHandler: { picked += 1 })
        tap.volumeSessionActive = true
        tap.transportKeysHijacked = false
        XCTAssertNil(tap.handle(type: systemDefinedType,
                                event: mediaKeyEvent(keyCode: 16, isDown: true, command: true)))
        XCTAssertNil(tap.handle(type: systemDefinedType,
                                event: mediaKeyEvent(keyCode: 16, isDown: true, isRepeat: true, command: true)))
        XCTAssertNil(tap.handle(type: systemDefinedType,
                                event: mediaKeyEvent(keyCode: 16, isDown: false, command: true)))
        drainMainQueue()
        XCTAssertEqual(picked, 1)
    }

    func testCommandPlayOpensPickerBeforePlaybackWhenOverlayIsClosed() {
        var events: [String] = []
        let tap = MediaKeyTap(handler: { _ in XCTFail("Must route through the picker") },
                             passthroughHandler: { _ in XCTFail("Must not reach system") },
                             commandVolumeHandler: { events.append("picker") },
                             pickerPlayPauseHandler: { events.append("playback") })
        tap.volumeSessionActive = false
        tap.transportKeysHijacked = false
        for (down, repeatKey) in [(true, false), (true, true), (false, false)] {
            XCTAssertNil(tap.handle(type: systemDefinedType,
                                    event: mediaKeyEvent(keyCode: 16, isDown: down,
                                                         isRepeat: repeatKey, command: true)))
        }
        drainMainQueue()
        XCTAssertEqual(events, ["picker", "playback"])
    }

    func testPlainPlayStillTargetsHookedAppDuringPicker() {
        var handled: [MediaKey] = []
        let tap = MediaKeyTap(handler: { handled.append($0) },
                             pickerPlayPauseHandler: { XCTFail("Plain play must keep its target") })
        tap.volumeSessionActive = true
        XCTAssertNil(tap.handle(type: systemDefinedType,
                                event: mediaKeyEvent(keyCode: 16, isDown: true)))
        drainMainQueue()
        XCTAssertEqual(handled, [.playPause])
    }

    func testCommandMuteOpensPickerBeforeTogglingAndIgnoresRepeatsAndKeyUp() {
        var events: [String] = []
        let tap = MediaKeyTap(handler: { _ in events.append("mute") },
                             commandVolumeHandler: { events.append("picker") })
        tap.targetCanTakeMute = true
        for (down, repeatKey) in [(true, false), (true, true), (false, false)] {
            XCTAssertNil(tap.handle(type: systemDefinedType,
                                    event: mediaKeyEvent(keyCode: 7, isDown: down,
                                                         isRepeat: repeatKey, command: true)))
        }
        drainMainQueue()
        XCTAssertEqual(events, ["picker", "mute"])
    }

    func testCommandMuteOpensPickerEvenWhenMutePassesToSystem() {
        var opened = 0
        let tap = MediaKeyTap(handler: { _ in XCTFail("Mute should pass through") },
                             commandVolumeHandler: { opened += 1 })
        let result = tap.handle(type: systemDefinedType,
                                event: mediaKeyEvent(keyCode: 7, isDown: true, command: true))
        drainMainQueue()
        XCTAssertNotNil(result)
        XCTAssertEqual(opened, 1)
    }

    func testCommandVolumeOpensPickerBeforeDeliveringStep() {
        var events: [String] = []
        let tap = MediaKeyTap(handler: { _ in events.append("step") },
                             commandVolumeHandler: { events.append("picker") })
        tap.targetCanTakeVolume = true
        _ = tap.handle(type: systemDefinedType,
                       event: mediaKeyEvent(keyCode: volumeUpKeyCode, isDown: true, command: true))
        drainMainQueue()
        XCTAssertEqual(events, ["picker", "step"])
    }

    func testCommandVolumeOpensPickerWhenTargetVolumeIsUnavailable() {
        var opened = 0
        let tap = MediaKeyTap(handler: { _ in XCTFail("Unavailable volume must pass through") },
                             commandVolumeHandler: { opened += 1 })
        let result = tap.handle(type: systemDefinedType,
                                event: mediaKeyEvent(keyCode: volumeUpKeyCode, isDown: true, command: true))
        drainMainQueue()
        XCTAssertNotNil(result)
        XCTAssertEqual(opened, 1)
    }

    func testPickerDoesNotOpenForPlainVolumeKeyUpOrDisabledCommandRouting() {
        var opened = 0
        let tap = MediaKeyTap(handler: { _ in }, commandVolumeHandler: { opened += 1 })
        _ = tap.handle(type: systemDefinedType,
                       event: mediaKeyEvent(keyCode: volumeUpKeyCode, isDown: true))
        _ = tap.handle(type: systemDefinedType,
                       event: mediaKeyEvent(keyCode: volumeUpKeyCode, isDown: false, command: true))
        tap.commandVolumeRouting = false
        _ = tap.handle(type: systemDefinedType,
                       event: mediaKeyEvent(keyCode: volumeUpKeyCode, isDown: true, command: true))
        drainMainQueue()
        XCTAssertEqual(opened, 0)
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

    // MARK: - Mute routing

    /// NX_KEYTYPE_MUTE.
    private let muteKeyCode = 7

    func testCommandMuteIsSwallowedForTheAppWhenTheVolumeKeysAreNotHooked() {
        var handled: [MediaKey] = []
        let tap = MediaKeyTap(handler: { handled.append($0) })
        tap.volumeKeysHijacked = false
        tap.commandVolumeRouting = true
        tap.targetCanTakeMute = true

        let result = tap.handle(type: systemDefinedType,
                                event: mediaKeyEvent(keyCode: muteKeyCode,
                                                     isDown: true, command: true))

        XCTAssertNil(result, "⌘ + mute must be swallowed and routed to the app")
        drainMainQueue()
        XCTAssertEqual(handled, [.mute])
    }

    func testPlainMuteStillReachesTheSystemWhenTheVolumeKeysAreNotHooked() {
        var handled: [MediaKey] = []
        let tap = MediaKeyTap(handler: { handled.append($0) })
        tap.volumeKeysHijacked = false
        tap.commandVolumeRouting = true
        tap.targetCanTakeMute = true

        let result = tap.handle(type: systemDefinedType,
                                event: mediaKeyEvent(keyCode: muteKeyCode, isDown: true))

        XCTAssertNotNil(result, "an unmodified mute key belongs to the system")
        drainMainQueue()
        XCTAssertTrue(handled.isEmpty)
    }

    /// The volume-keys checkbox flips the whole cluster: with it on, plain mute
    /// mutes the hooked app and ⌘ + mute becomes the escape to the system.
    func testPlainMuteIsSwallowedForTheAppWhenTheVolumeKeysAreHooked() {
        var handled: [MediaKey] = []
        let tap = MediaKeyTap(handler: { handled.append($0) })
        tap.volumeKeysHijacked = true
        tap.targetCanTakeMute = true

        let result = tap.handle(type: systemDefinedType,
                                event: mediaKeyEvent(keyCode: muteKeyCode, isDown: true))

        XCTAssertNil(result)
        drainMainQueue()
        XCTAssertEqual(handled, [.mute])
    }

    func testCommandMuteEscapesToTheSystemWithTheModifierStripped() {
        let tap = MediaKeyTap { _ in }
        tap.volumeKeysHijacked = true
        tap.targetCanTakeMute = true

        let result = tap.handle(type: systemDefinedType,
                                event: mediaKeyEvent(keyCode: muteKeyCode,
                                                     isDown: true, command: true))

        let passed = try? XCTUnwrap(result?.takeUnretainedValue())
        XCTAssertNotNil(passed)
        XCTAssertFalse(passed!.flags.contains(.maskCommand),
                       "macOS must receive an ordinary mute key, not a modified shortcut")
    }

    /// Per-app mute off, or the target quit: every mute press belongs to macOS.
    func testMuteReachesTheSystemWhenTheTargetCannotTakeIt() {
        for hijacked in [true, false] {
            for command in [true, false] {
                var handled: [MediaKey] = []
                let tap = MediaKeyTap(handler: { handled.append($0) })
                tap.volumeKeysHijacked = hijacked
                tap.commandVolumeRouting = true
                tap.targetCanTakeMute = false

                let result = tap.handle(type: systemDefinedType,
                                        event: mediaKeyEvent(keyCode: muteKeyCode,
                                                             isDown: true, command: command))

                XCTAssertNotNil(result, "hijacked=\(hijacked) command=\(command)")
                drainMainQueue()
                XCTAssertTrue(handled.isEmpty, "hijacked=\(hijacked) command=\(command)")
            }
        }
    }

    /// Mute is a toggle: a held key must not flap it, but the repeats and the
    /// key-up still have to be swallowed so the system's mute never fires.
    func testHookedMuteRepeatsAndKeyUpAreSwallowedWithoutForwarding() {
        var handled: [MediaKey] = []
        let tap = MediaKeyTap(handler: { handled.append($0) })
        tap.volumeKeysHijacked = true
        tap.targetCanTakeMute = true

        let repeatResult = tap.handle(type: systemDefinedType,
                                      event: mediaKeyEvent(keyCode: muteKeyCode,
                                                           isDown: true, isRepeat: true))
        let upResult = tap.handle(type: systemDefinedType,
                                  event: mediaKeyEvent(keyCode: muteKeyCode, isDown: false))

        XCTAssertNil(repeatResult)
        XCTAssertNil(upResult)
        drainMainQueue()
        XCTAssertTrue(handled.isEmpty)
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

    // MARK: - Volume-source picker session

    func testHookedSessionCommandVolumeEscapesWithoutOpeningPicker() {
        var events: [String] = []
        let tap = MediaKeyTap(handler: { _ in events.append("step") },
                             commandVolumeHandler: { events.append("picker") })
        tap.volumeKeysHijacked = true
        tap.targetCanTakeVolume = true
        tap.volumeSessionActive = true
        tap.volumeSessionCanTakeVolume = true
        let event = mediaKeyEvent(keyCode: volumeUpKeyCode, isDown: true, command: true)
        XCTAssertNotNil(tap.handle(type: systemDefinedType, event: event))
        XCTAssertFalse(event.flags.contains(.maskCommand))
        drainMainQueue()
        XCTAssertTrue(events.isEmpty)
    }

    func testHookedPlainVolumeOpensPickerBeforeStep() {
        var events: [String] = []
        let tap = MediaKeyTap(handler: { _ in events.append("step") },
                             commandVolumeHandler: { events.append("picker") })
        tap.volumeKeysHijacked = true
        tap.targetCanTakeVolume = true
        XCTAssertNil(tap.handle(type: systemDefinedType,
                               event: mediaKeyEvent(keyCode: volumeUpKeyCode, isDown: true)))
        drainMainQueue()
        XCTAssertEqual(events, ["picker", "step"])
    }

    func testHookedPlainPlayControlsPickerSelection() {
        var events: [String] = []
        let tap = MediaKeyTap(handler: { _ in XCTFail("Expected picker playback") },
                             commandVolumeHandler: { events.append("picker") },
                             pickerPlayPauseHandler: { events.append("play") })
        tap.volumeKeysHijacked = true
        tap.volumeSessionActive = true
        XCTAssertNil(tap.handle(type: systemDefinedType,
                               event: mediaKeyEvent(keyCode: 16, isDown: true)))
        drainMainQueue()
        XCTAssertEqual(events, ["picker", "play"])
    }

    func testSessionRoutesPlainVolumeEvenWithTheHookOff() {
        var handled: [MediaKey] = []
        let tap = MediaKeyTap(handler: { handled.append($0) })
        tap.volumeKeysHijacked = false
        tap.commandVolumeRouting = false
        tap.volumeSessionActive = true
        tap.volumeSessionCanTakeVolume = true

        let result = tap.handle(type: systemDefinedType,
                                event: mediaKeyEvent(keyCode: volumeUpKeyCode, isDown: true))

        XCTAssertNil(result)
        drainMainQueue()
        XCTAssertEqual(handled, [.volumeUp])
    }

    func testSessionEndingHandsCommandVolumeBackToTheSystem() {
        var handled: [MediaKey] = []
        let tap = MediaKeyTap(handler: { handled.append($0) })
        tap.volumeKeysHijacked = true
        tap.targetCanTakeVolume = true
        tap.volumeSessionActive = true
        tap.volumeSessionCanTakeVolume = true
        tap.volumeSessionActive = false

        let event = mediaKeyEvent(keyCode: volumeUpKeyCode, isDown: true, command: true)
        let result = tap.handle(type: systemDefinedType, event: event)

        XCTAssertNotNil(result)
        XCTAssertFalse(event.flags.contains(.maskCommand))
        drainMainQueue()
        XCTAssertTrue(handled.isEmpty)
    }

    /// The picked source quit (or the list is empty): the keys go to the
    /// system even though the hooked app could take them.
    func testSessionHandsVolumeToTheSystemWhenThePickedSourceCannotTakeIt() {
        var handled: [MediaKey] = []
        let tap = MediaKeyTap(handler: { handled.append($0) })
        tap.volumeKeysHijacked = true
        tap.targetCanTakeVolume = true
        tap.volumeSessionActive = true
        tap.volumeSessionCanTakeVolume = false

        let event = mediaKeyEvent(keyCode: volumeUpKeyCode, isDown: true, command: true)
        let result = tap.handle(type: systemDefinedType, event: event)

        XCTAssertNotNil(result)
        XCTAssertFalse(event.flags.contains(.maskCommand))
        drainMainQueue()
        XCTAssertTrue(handled.isEmpty)
    }

    func testHookedSessionCommandMuteEscapesToSystem() {
        var handled: [MediaKey] = []
        let tap = MediaKeyTap(handler: { handled.append($0) })
        tap.volumeKeysHijacked = true
        tap.targetCanTakeMute = true
        tap.volumeSessionActive = true
        tap.volumeSessionCanTakeMute = true
        let event = mediaKeyEvent(keyCode: muteKeyCode, isDown: true, command: true)
        XCTAssertNotNil(tap.handle(type: systemDefinedType, event: event))
        XCTAssertFalse(event.flags.contains(.maskCommand))
        drainMainQueue()
        XCTAssertTrue(handled.isEmpty)
    }

    /// A browser tab can be muted (through its volume) even with per-app mute
    /// off, so the session's capability, not the hooked app's, decides.
    func testSessionCommandMuteFollowsThePickedSourceNotTheHookedApp() {
        var handled: [MediaKey] = []
        let tap = MediaKeyTap(handler: { handled.append($0) })
        tap.targetCanTakeMute = false
        tap.volumeSessionActive = true
        tap.volumeSessionCanTakeMute = true

        let result = tap.handle(type: systemDefinedType,
                                event: mediaKeyEvent(keyCode: muteKeyCode, isDown: true, command: true))

        XCTAssertNil(result)
        drainMainQueue()
        XCTAssertEqual(handled, [.mute])
    }

    func testSessionCommandMuteReachesTheSystemWhenThePickedSourceCannotBeMuted() {
        var handled: [MediaKey] = []
        let tap = MediaKeyTap(handler: { handled.append($0) })
        tap.volumeKeysHijacked = false
        tap.targetCanTakeMute = true
        tap.volumeSessionActive = true
        tap.volumeSessionCanTakeMute = false

        let event = mediaKeyEvent(keyCode: muteKeyCode, isDown: true, command: true)
        let result = tap.handle(type: systemDefinedType, event: event)

        XCTAssertNotNil(result)
        XCTAssertFalse(event.flags.contains(.maskCommand),
                       "macOS must receive an ordinary mute key, not a modified shortcut")
        drainMainQueue()
        XCTAssertTrue(handled.isEmpty)
    }

    /// Plain mute keeps its ordinary rule in a session: with the hook off it
    /// still belongs to the system.
    func testSessionLeavesPlainMuteToTheSystemWithTheHookOff() {
        var handled: [MediaKey] = []
        let tap = MediaKeyTap(handler: { handled.append($0) })
        tap.volumeKeysHijacked = false
        tap.targetCanTakeMute = true
        tap.volumeSessionActive = true
        tap.volumeSessionCanTakeMute = true

        let event = mediaKeyEvent(keyCode: muteKeyCode, isDown: true)
        withExtendedLifetime(event) {
            XCTAssertTrue(tap.handle(type: systemDefinedType, event: event) != nil)
        }
        drainMainQueue()
        XCTAssertTrue(handled.isEmpty)
    }

    /// With the hook on, plain Mute acts on the picked source in a session, so
    /// it is gated on that source: a picked tab works with per-app mute off…
    func testSessionHookedPlainMuteFollowsThePickedSource() {
        var handled: [MediaKey] = []
        let tap = MediaKeyTap(handler: { handled.append($0) })
        tap.volumeKeysHijacked = true
        tap.targetCanTakeMute = false
        tap.volumeSessionActive = true
        tap.volumeSessionCanTakeMute = true

        let result = tap.handle(type: systemDefinedType,
                                event: mediaKeyEvent(keyCode: muteKeyCode, isDown: true))

        XCTAssertNil(result)
        drainMainQueue()
        XCTAssertEqual(handled, [.mute])
    }

    /// …and a picked app that quit hands the press back to the system even
    /// though the hooked app could be muted.
    func testSessionHookedPlainMuteReachesTheSystemWhenThePickedSourceCannotBeMuted() {
        var handled: [MediaKey] = []
        let tap = MediaKeyTap(handler: { handled.append($0) })
        tap.volumeKeysHijacked = true
        tap.targetCanTakeMute = true
        tap.volumeSessionActive = true
        tap.volumeSessionCanTakeMute = false

        let event = mediaKeyEvent(keyCode: muteKeyCode, isDown: true)
        let result = tap.handle(type: systemDefinedType, event: event)

        XCTAssertTrue(result?.takeUnretainedValue() === event)
        drainMainQueue()
        XCTAssertTrue(handled.isEmpty)
    }

    func testHeldSessionCommandMuteDoesNotFlapTheToggle() {
        var handled: [MediaKey] = []
        let tap = MediaKeyTap(handler: { handled.append($0) })
        tap.volumeSessionActive = true
        tap.volumeSessionCanTakeMute = true

        let result = tap.handle(type: systemDefinedType,
                                event: mediaKeyEvent(keyCode: muteKeyCode, isDown: true,
                                                     isRepeat: true, command: true))

        XCTAssertNil(result, "still swallowed so macOS doesn't toggle system mute")
        drainMainQueue()
        XCTAssertTrue(handled.isEmpty, "a repeat must not toggle again")
    }
}
