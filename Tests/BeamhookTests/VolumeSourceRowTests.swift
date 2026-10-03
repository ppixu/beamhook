import XCTest
@testable import Beamhook

@MainActor
final class VolumeSourceRowTests: XCTestCase {
    func testMuteOnlyAppExplainsUnavailableVolume() {
        let row = HookHUD.SourceRow(name: "ChatGPT", percent: nil, canMute: true)
        XCTAssertEqual(row.statusText, "Volume unavailable · Mute available")
        XCTAssertFalse(row.isMuted, "An unavailable reading must not look like zero volume")
    }

    func testMutedAppStillExplainsUnavailableVolume() {
        let row = HookHUD.SourceRow(name: "ChatGPT", percent: nil, muted: true, canMute: true)
        XCTAssertEqual(row.statusText, "Volume unavailable · Muted")
    }

    func testAppWithoutControlsIsStillDescribed() {
        let row = HookHUD.SourceRow(name: "App", percent: nil)
        XCTAssertEqual(row.statusText, "Volume unavailable · Mute unavailable")
    }

    func testZeroVolumeIsMuted() {
        XCTAssertEqual(HookHUD.SourceRow(name: "Tab", percent: 0).statusText, "Muted")
        XCTAssertEqual(HookHUD.SourceRow(name: "Spotify", percent: 45).statusText, "45 percent")
    }
}
