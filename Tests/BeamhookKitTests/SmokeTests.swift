import XCTest
@testable import BeamhookKit

final class SmokeTests: XCTestCase {
    func testFrameworkLinks() {
        XCTAssertTrue(true)
    }
}

final class VolumeKeyRoutingTests: XCTestCase {
    func testVolumeKeysAreNotHijackedByDefault() {
        XCTAssertFalse(VolumeKeyRouting.shouldHijack(
            targetBundleID: "com.example.player",
            targetSupportsVolume: true,
            preferences: [:]
        ))
    }

    func testVolumeKeysAreHijackedAfterExplicitOptIn() {
        XCTAssertTrue(VolumeKeyRouting.shouldHijack(
            targetBundleID: "com.example.player",
            targetSupportsVolume: true,
            preferences: ["com.example.player": true]
        ))
    }

    func testVolumeKeysRemainAvailableForUnsupportedTarget() {
        XCTAssertFalse(VolumeKeyRouting.shouldHijack(
            targetBundleID: "com.example.player",
            targetSupportsVolume: false,
            preferences: ["com.example.player": true]
        ))
    }
}
