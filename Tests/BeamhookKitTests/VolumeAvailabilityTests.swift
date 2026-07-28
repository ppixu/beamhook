import XCTest
@testable import BeamhookKit

final class VolumeAvailabilityTests: XCTestCase {
    func testSuccessfulReadShowsTheSlider() {
        XCTAssertEqual(
            VolumeAvailability.resolve(definitionSupportsVolume: true,
                                       readSucceeded: true, automationAllowed: true),
            .slider)
    }

    func testAppWithoutVolumeSupportIsSystemVolumeOnly() {
        // A menu-driven target: no volume scripts at all, so a denied permission
        // is beside the point and must not be blamed.
        XCTAssertEqual(
            VolumeAvailability.resolve(definitionSupportsVolume: false,
                                       readSucceeded: false, automationAllowed: false),
            .systemVolumeOnly)
    }

    func testScriptableAppWithDeniedPermissionReportsTheDenial() {
        XCTAssertEqual(
            VolumeAvailability.resolve(definitionSupportsVolume: true,
                                       readSucceeded: false, automationAllowed: false),
            .permissionDenied)
    }

    func testUnknownPermissionDoesNotAccuseTheUser() {
        // Permission not yet requested, or the check itself failed: the read may
        // have failed for any number of reasons, so say the neutral thing.
        XCTAssertEqual(
            VolumeAvailability.resolve(definitionSupportsVolume: true,
                                       readSucceeded: false, automationAllowed: nil),
            .systemVolumeOnly)
    }

    func testPermissionIsIrrelevantOnceTheReadWorked() {
        // A stale "denied" answer must never hide a slider that is demonstrably
        // working — the successful read is the stronger evidence.
        XCTAssertEqual(
            VolumeAvailability.resolve(definitionSupportsVolume: true,
                                       readSucceeded: true, automationAllowed: false),
            .slider)
    }
}
