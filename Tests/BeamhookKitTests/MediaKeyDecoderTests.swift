import XCTest
@testable import BeamhookKit

final class MediaKeyDecoderTests: XCTestCase {
    // data1 = (keyCode << 16) | (keyState << 8) | repeatBit

    func testPlayKeyDown() {
        let e = MediaKeyDecoder.decode(subtype: 8, data1: 0x100A00)  // play, state down, no repeat
        XCTAssertEqual(e, MediaKeyEvent(key: .playPause, isDown: true, isRepeat: false))
    }

    func testPlayKeyUp() {
        let e = MediaKeyDecoder.decode(subtype: 8, data1: 0x100B00)  // play, state up
        XCTAssertEqual(e, MediaKeyEvent(key: .playPause, isDown: false, isRepeat: false))
    }

    func testPlayKeyDownRepeat() {
        let e = MediaKeyDecoder.decode(subtype: 8, data1: 0x100A01)  // play, down, repeat bit set
        XCTAssertEqual(e, MediaKeyEvent(key: .playPause, isDown: true, isRepeat: true))
    }

    func testNextAndPrevious() {
        XCTAssertEqual(MediaKeyDecoder.decode(subtype: 8, data1: 0x110A00)?.key, .next)
        XCTAssertEqual(MediaKeyDecoder.decode(subtype: 8, data1: 0x120A00)?.key, .previous)
    }

    func testVolumeKeys() {
        XCTAssertEqual(MediaKeyDecoder.decode(subtype: 8, data1: 0x000A00)?.key, .volumeUp)   // SOUND_UP = 0
        XCTAssertEqual(MediaKeyDecoder.decode(subtype: 8, data1: 0x010A00)?.key, .volumeDown) // SOUND_DOWN = 1
        XCTAssertEqual(MediaKeyDecoder.decode(subtype: 8, data1: 0x070A00)?.key, .mute)        // MUTE = 7
    }

    func testWrongSubtypeReturnsNil() {
        XCTAssertNil(MediaKeyDecoder.decode(subtype: 7, data1: 0x100A00))
    }

    func testUnknownKeycodeReturnsNil() {
        XCTAssertNil(MediaKeyDecoder.decode(subtype: 8, data1: 0x630A00)) // keycode 99, unmapped
    }

    func testIsHandledTransport() {
        XCTAssertTrue(MediaKey.playPause.isHandledTransport)
        XCTAssertTrue(MediaKey.next.isHandledTransport)
        XCTAssertTrue(MediaKey.previous.isHandledTransport)
        XCTAssertFalse(MediaKey.volumeUp.isHandledTransport)
        XCTAssertFalse(MediaKey.fastForward.isHandledTransport)
    }

    func testCommandMapping() {
        XCTAssertEqual(MediaKey.playPause.command, .playPause)
        XCTAssertEqual(MediaKey.next.command, .next)
        XCTAssertEqual(MediaKey.previous.command, .previous)
        XCTAssertNil(MediaKey.volumeUp.command)
    }
}
