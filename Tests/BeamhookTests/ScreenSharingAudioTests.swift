import XCTest
@testable import Beamhook

@MainActor
final class ScreenSharingAudioTests: XCTestCase {
    private let app = ScreenSharingAudio.app

    func testRunningScreenSharingIsInFullListButSilentAppIsNotShortlisted() {
        let state = AppState()
        let rows = state.menuAppRows([], runningBundleIDs: [app.bundleID])
        XCTAssertTrue(rows.contains(app))
        XCTAssertFalse(state.recentAppRows(rows).contains(app))

        state.updateAudibleApps([app.bundleID])
        XCTAssertTrue(state.recentAppRows(rows).contains(app))
        state.updateAudibleApps([])
        XCTAssertTrue(state.recentAppRows(rows).contains(app))
    }

    func testQuitScreenSharingIsAbsentAndObservedAppIsNotDuplicated() {
        let state = AppState()
        XCTAssertFalse(state.menuAppRows([], runningBundleIDs: []).contains(app))
        let rows = state.menuAppRows([app], runningBundleIDs: [app.bundleID])
        XCTAssertEqual(rows.filter { $0.bundleID == app.bundleID }, [app])
    }

    func testConferenceAudioResolvesToRunningScreenSharing() {
        XCTAssertEqual(ScreenSharingAudio.identity(for: "com.apple.avconferenced",
                                                  runningBundleIDs: [app.bundleID]), app)
        XCTAssertNil(ScreenSharingAudio.identity(for: "com.apple.avconferenced", runningBundleIDs: []))
        XCTAssertNil(ScreenSharingAudio.identity(for: "com.apple.unrelated", runningBundleIDs: [app.bundleID]))
    }

    func testSharedConferenceAudioDoesNotInheritScreenSharingControls() {
        let shared = ScreenSharingAudio.identity(for: "com.apple.avconferenced",
                                                runningBundleIDs: [app.bundleID, "com.apple.FaceTime"])
        XCTAssertEqual(shared?.bundleID, "com.apple.avconferenced")
        XCTAssertNotEqual(shared?.bundleID, app.bundleID)
    }
}
