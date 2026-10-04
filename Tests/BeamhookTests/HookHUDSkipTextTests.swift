import XCTest
@testable import Beamhook

final class HookHUDSkipTextTests: XCTestCase {
    func testSkipTextShowsSignedSecondsOrMenuWords() {
        XCTAssertEqual(HookHUD.skipText(seconds: 15, byMenu: false), "+15 s")
        XCTAssertEqual(HookHUD.skipText(seconds: -10, byMenu: false), "\u{2212}10 s")
        XCTAssertEqual(HookHUD.skipText(seconds: 30, byMenu: true), "Skip forward")
        XCTAssertEqual(HookHUD.skipText(seconds: -15, byMenu: true), "Skip back")
    }
}
