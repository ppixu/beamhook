import XCTest
@testable import Beamhook

/// The picker session lays the tab levels its keys wrote over scanned browser
/// data, so a scan taken before a send can't roll a tab back.
final class SessionTabVolumesTests: XCTestCase {
    private func candidate(_ sourceID: String, volume: Int?) -> BrowserMediaCandidate {
        BrowserMediaCandidate(
            browser: .chrome,
            sourceID: sourceID,
            windowIndex: 1,
            tabIndex: 1,
            title: "Tab \(sourceID)",
            artist: "",
            host: "www.youtube.com",
            isPlaying: true,
            isSelected: false,
            supportsTransport: true,
            volume: volume
        )
    }

    func testEmptyMapReturnsTheScanUnchanged() {
        let scan = [candidate("a", volume: 40), candidate("b", volume: nil)]
        XCTAssertEqual(AppState.applyingSessionTabVolumes([:], to: scan), scan)
    }

    func testKeyWrittenLevelsWinOverScannedOnes() {
        let scan = [candidate("a", volume: 40), candidate("b", volume: 70)]
        let patched = AppState.applyingSessionTabVolumes([scan[0].id: 12], to: scan)
        XCTAssertEqual(patched.map(\.volume), [12, 70])
        XCTAssertEqual(patched.map(\.id), scan.map(\.id), "order and identity are kept")
    }

    func testLevelsForTabsMissingFromTheScanAreIgnored() {
        let scan = [candidate("a", volume: 40)]
        let patched = AppState.applyingSessionTabVolumes(["chrome:gone": 0], to: scan)
        XCTAssertEqual(patched, scan)
    }

    func testAPatchFillsInATabTheScanCouldNotRead() {
        let scan = [candidate("a", volume: nil)]
        let patched = AppState.applyingSessionTabVolumes([scan[0].id: 0], to: scan)
        XCTAssertEqual(patched.first?.volume, 0)
    }
}
