import XCTest
@testable import Beamhook
import BeamhookKit

final class SourcePickerKeyTapTests: XCTestCase {
    private func keyEvent(_ keyCode: CGKeyCode, down: Bool = true,
                          flags: CGEventFlags = .maskCommand) -> CGEvent {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: down)!
        event.flags = flags
        return event
    }

    private func drainMainQueue() {
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 1)
    }

    func testCommandArrowsAreSwallowedAndReported() {
        var keys: [SourcePickerKey] = []
        let tap = SourcePickerKeyTap { keys.append($0) }

        XCTAssertNil(tap.handle(type: .keyDown, event: keyEvent(126)))
        XCTAssertNil(tap.handle(type: .keyDown, event: keyEvent(125)))

        drainMainQueue()
        XCTAssertEqual(keys, [.previous, .next])
    }

    func testFnAndNumericPadFlagsAreIgnored() {
        var keys: [SourcePickerKey] = []
        let tap = SourcePickerKeyTap { keys.append($0) }

        let flags: CGEventFlags = [.maskCommand, .maskSecondaryFn, .maskNumericPad]
        XCTAssertNil(tap.handle(type: .keyDown, event: keyEvent(116, flags: flags)))

        drainMainQueue()
        XCTAssertEqual(keys, [.previous])
    }

    func testKeyUpIsSwallowedButNotReported() {
        var keys: [SourcePickerKey] = []
        let tap = SourcePickerKeyTap { keys.append($0) }

        XCTAssertNil(tap.handle(type: .keyUp, event: keyEvent(126, down: false)))

        drainMainQueue()
        XCTAssertTrue(keys.isEmpty)
    }

    func testOtherKeystrokesPassUntouched() {
        var keys: [SourcePickerKey] = []
        let tap = SourcePickerKeyTap { keys.append($0) }

        // The events are kept alive across the asserts: a passed-through result
        // is an unretained reference to them, and XCTAssertNotNil reflects over
        // its argument, which crashes if the event has already been freed.
        let events = [keyEvent(126, flags: []),
                      keyEvent(126, flags: [.maskCommand, .maskShift]),
                      keyEvent(0)]   // ⌘A
        withExtendedLifetime(events) {
            for event in events {
                XCTAssertTrue(tap.handle(type: .keyDown, event: event) != nil)
            }
        }

        drainMainQueue()
        XCTAssertTrue(keys.isEmpty)
    }

    func testDisarmWithoutArmIsHarmless() {
        let tap = SourcePickerKeyTap { _ in }
        tap.disarm()
        tap.disarm()
    }
}
