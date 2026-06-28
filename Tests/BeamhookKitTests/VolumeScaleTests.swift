import XCTest
@testable import BeamhookKit

final class VolumeScaleTests: XCTestCase {
    func testIntegerToPercent() {
        XCTAssertEqual(VolumeScale.toPercent(raw: 256, kind: .integer(max: 512)), 50)
        XCTAssertEqual(VolumeScale.toPercent(raw: 512, kind: .integer(max: 512)), 100)
        XCTAssertEqual(VolumeScale.toPercent(raw: 0, kind: .integer(max: 512)), 0)
        XCTAssertEqual(VolumeScale.toPercent(raw: 75, kind: .integer(max: 100)), 75)
    }

    func testUnitFloatToPercent() {
        XCTAssertEqual(VolumeScale.toPercent(raw: 0.75, kind: .unitFloat), 75)
        XCTAssertEqual(VolumeScale.toPercent(raw: 1.0, kind: .unitFloat), 100)
    }

    func testNoneToPercentIsNil() {
        XCTAssertNil(VolumeScale.toPercent(raw: 50, kind: .none))
    }

    func testPercentToRawString() {
        XCTAssertEqual(VolumeScale.rawString(fromPercent: 50, kind: .integer(max: 512)), "256")
        XCTAssertEqual(VolumeScale.rawString(fromPercent: 75, kind: .integer(max: 100)), "75")
        XCTAssertEqual(VolumeScale.rawString(fromPercent: 75, kind: .unitFloat), "0.750")
        XCTAssertNil(VolumeScale.rawString(fromPercent: 50, kind: .none))
    }

    func testIntegerMaxZeroReturnsNil() {
        XCTAssertNil(VolumeScale.toPercent(raw: 0, kind: .integer(max: 0)))
        XCTAssertNil(VolumeScale.rawString(fromPercent: 50, kind: .integer(max: 0)))
    }

    func testPercentClamps() {
        XCTAssertEqual(VolumeScale.toPercent(raw: 600, kind: .integer(max: 512)), 100)
        XCTAssertEqual(VolumeScale.rawString(fromPercent: 150, kind: .integer(max: 100)), "100")
        XCTAssertEqual(VolumeScale.rawString(fromPercent: -10, kind: .integer(max: 100)), "0")
    }
}
