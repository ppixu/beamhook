import XCTest
@testable import BeamhookKit

final class PassthroughNoticeTests: XCTestCase {
    func testQuitBrowserIsReportedAsNotRunning() {
        XCTAssertEqual(
            PassthroughNotice.resolve(browserRunningNow: false,
                                      scanSawBrowserRunning: false,
                                      injectionAvailable: false),
            .browserNotRunning)
    }

    func testMissingInjectionPointsAtTheJavaScriptSetting() {
        XCTAssertEqual(
            PassthroughNotice.resolve(browserRunningNow: true,
                                      scanSawBrowserRunning: true,
                                      injectionAvailable: false),
            .enableBrowserJavaScript)
    }

    func testPendingScanStaysNeutral() {
        // The browser was just hooked and no scan has answered yet: we don't
        // know whether injection works, so don't accuse the user's settings.
        XCTAssertEqual(
            PassthroughNotice.resolve(browserRunningNow: true,
                                      scanSawBrowserRunning: nil,
                                      injectionAvailable: nil),
            .handledByMacOS)
    }

    func testStaleNotRunningScanDoesNotBlameJavaScript() {
        // The last scan ran while the browser was quit, which records
        // injectionAvailable == false as a side effect. The browser has since
        // launched; that stale false must not produce the JavaScript hint.
        XCTAssertEqual(
            PassthroughNotice.resolve(browserRunningNow: true,
                                      scanSawBrowserRunning: false,
                                      injectionAvailable: false),
            .handledByMacOS)
    }

    func testLiveRunningStateBeatsStaleScan() {
        // Browser quit after the last scan: the live check wins.
        XCTAssertEqual(
            PassthroughNotice.resolve(browserRunningNow: false,
                                      scanSawBrowserRunning: true,
                                      injectionAvailable: true),
            .browserNotRunning)
    }
}
