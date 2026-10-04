import XCTest
import CoreAudio
@testable import Beamhook

final class ProcessVolumeErrorTests: XCTestCase {
    @MainActor
    func testFullVolumeReleasesControlAndDisablingClearsSavedMute() throws {
        guard #available(macOS 14.2, *) else { throw XCTSkip("Process taps require macOS 14.2") }
        let suite = "ProcessVolumeErrorTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = ProcessMuteController(defaults: defaults)
        let app = "com.example.beamhook-audio-regression"
        controller.setVolume(30, bundleID: app)
        XCTAssertEqual(controller.volumes[app], 30)
        controller.setVolume(100, bundleID: app)
        XCTAssertNil(controller.volumes[app], "Unity must remove the request for a playback tap")
        XCTAssertEqual(controller.volume(for: app), 100)
        controller.setMuted(true, bundleID: app)
        controller.stopAndClear()
        XCTAssertTrue(controller.mutedBundleIDs.isEmpty)
        XCTAssertNil(defaults.object(forKey: "perAppMutedBundleIDs"))
        XCTAssertNil(defaults.object(forKey: "perAppVolumes"))
    }

    func testRenderFailureStaysBypassedAcrossPollsUntilConfigurationChanges() throws {
        guard #available(macOS 14.2, *) else { throw XCTSkip("Process taps require macOS 14.2") }
        var failures = ProcessMuteController.RenderFailures()
        let safari = "com.apple.Safari"
        failures.record(42, bundleID: safari, gain: 0.5)
        for _ in 0..<5 {
            failures.reconcile(wanted: [42: safari, 43: "other"], muted: [], levels: [safari: 50])
            XCTAssertTrue(failures.contains(42))
            XCTAssertFalse(failures.contains(43), "Other audio processes remain controllable")
            XCTAssertNotNil(failures.errors[safari])
        }
        failures.reconcile(wanted: [42: safari], muted: [], levels: [safari: 60])
        XCTAssertFalse(failures.contains(42))
        XCTAssertTrue(failures.errors.isEmpty)
    }

    func testRenderFailureDoesNotPreventExplicitMuteOrOutliveItsProcess() throws {
        guard #available(macOS 14.2, *) else { throw XCTSkip("Process taps require macOS 14.2") }
        var failures = ProcessMuteController.RenderFailures()
        let safari = "com.apple.Safari"
        failures.record(42, bundleID: safari, gain: 0.5)
        failures.reconcile(wanted: [42: safari], muted: [safari], levels: [safari: 50])
        XCTAssertFalse(failures.contains(42))
        failures.record(42, bundleID: safari, gain: 0.5)
        failures.reconcile(wanted: [43: safari], muted: [], levels: [safari: 50])
        XCTAssertTrue(failures.errors.isEmpty)
        failures.record(43, bundleID: safari, gain: 0.5)
        failures.clear() // Output/format change or explicit permission re-check.
        XCTAssertFalse(failures.contains(43))
        XCTAssertTrue(failures.errors.isEmpty)
    }

    func testIdleHelperFailureDoesNotDisableAppVolume() throws {
        guard #available(macOS 14.2, *) else { throw XCTSkip("Process taps require macOS 14.2") }
        for status in [kAudioDeviceUnsupportedFormatError, kAudioHardwareUnspecifiedError,
                       kAudioHardwareBadObjectError] {
            XCTAssertNil(ProcessMuteController.volumeError(for: status, isRunningOutput: false))
        }
    }

    func testActiveOutputFailureStillExplainsUnavailableVolume() throws {
        guard #available(macOS 14.2, *) else { throw XCTSkip("Process taps require macOS 14.2") }
        XCTAssertNotNil(ProcessMuteController.volumeError(
            for: kAudioDeviceUnsupportedFormatError, isRunningOutput: true))
        XCTAssertNotNil(ProcessMuteController.volumeError(
            for: kAudioHardwareUnspecifiedError, isRunningOutput: true))
        XCTAssertNil(ProcessMuteController.volumeError(
            for: kAudioHardwareBadObjectError, isRunningOutput: true))
        XCTAssertNil(ProcessMuteController.volumeError(for: noErr, isRunningOutput: true))
    }
}
