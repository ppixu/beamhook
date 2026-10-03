import XCTest
@testable import BeamhookKit

final class SourcePickerKeyTests: XCTestCase {
    private func match(_ keyCode: Int, command: Bool = true, shift: Bool = false,
                       option: Bool = false, control: Bool = false) -> SourcePickerKey? {
        SourcePickerKey.match(keyCode: keyCode, command: command, shift: shift,
                              option: option, control: control)
    }

    func testCommandArrowsMatch() {
        XCTAssertEqual(match(126), .previous)   // ↑
        XCTAssertEqual(match(125), .next)       // ↓
    }

    func testCommandPageKeysAreAliases() {
        XCTAssertEqual(match(116), .previous)   // PgUp
        XCTAssertEqual(match(121), .next)       // PgDn
    }

    func testBareArrowsDoNotMatch() {
        XCTAssertNil(match(126, command: false))
        XCTAssertNil(match(125, command: false))
    }

    func testExtraModifiersDoNotMatch() {
        XCTAssertNil(match(126, shift: true))    // ⌘⇧↑ = select to start
        XCTAssertNil(match(125, option: true))
        XCTAssertNil(match(126, control: true))
    }

    func testOtherKeysDoNotMatch() {
        XCTAssertNil(match(123))   // ←
        XCTAssertNil(match(124))   // →
        XCTAssertNil(match(0))     // A
    }
}
