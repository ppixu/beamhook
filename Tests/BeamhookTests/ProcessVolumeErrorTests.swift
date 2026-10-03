import XCTest
import CoreAudio
@testable import Beamhook

final class ProcessVolumeErrorTests: XCTestCase {
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
