import XCTest
import BeamhookKit
@testable import Beamhook

final class QuickTimeMediaControllerTests: XCTestCase {
    func testScriptsCompileAgainstInstalledQuickTimeDictionary() throws {
        let movie = QuickTimeMovie(processID: 42, windowID: 123, title: "Movie", isPlaying: false)
        for source in [try XCTUnwrap(BuiltInApps.quickTime.playPauseScript),
                       QuickTimeMediaController.scanScript,
                       QuickTimeMediaController.script(for: movie, toggle: true),
                       QuickTimeMediaController.script(for: movie, toggle: false),
                       QuickTimeMediaController.seekScript(for: movie, seconds: -15)] {
            let script = try XCTUnwrap(NSAppleScript(source: "with timeout of 5 seconds\n\(source)\nend timeout"))
            var error: NSDictionary?
            XCTAssertTrue(script.compileAndReturnError(&error), "\(error ?? [:])")
        }
    }

    func testDuplicateTitlesAndWindowReorderingPreserveIdentity() throws {
        let executor = QuickTimeExecutor()
        let controller = QuickTimeMediaController(executor: executor, processID: { 42 })
        executor.output = "OK\n12\ttrue\tSame title\n34\tfalse\tSame title\n"
        let original = try XCTUnwrap(controller.scan())
        XCTAssertEqual(original.map(\.id), ["42:12", "42:34"])
        executor.output = "OK\n34\tfalse\tSame title\n12\ttrue\tSame title\n"
        XCTAssertEqual(controller.scan()?.last, original.first)
        executor.output = "OK"
        XCTAssertTrue(controller.toggle(original[0]))
        XCTAssertTrue(executor.scripts.last?.contains("document of window id 12") == true)
        XCTAssertFalse(executor.scripts.last?.contains("document 1") == true)
    }

    func testRestartRejectsOldMovieWithoutSendingCommand() throws {
        let executor = QuickTimeExecutor()
        var pid: Int32? = 42
        let controller = QuickTimeMediaController(executor: executor, processID: { pid })
        executor.output = "OK\n12\tfalse\tMovie\n"
        let movie = try XCTUnwrap(controller.scan()?.first)
        let count = executor.scripts.count
        pid = 43
        XCTAssertFalse(controller.toggle(movie))
        XCTAssertNil(controller.isPlaying(movie))
        XCTAssertEqual(executor.scripts.count, count)
        pid = nil
        XCTAssertEqual(controller.scan(), [])
    }

    func testMissingMovieAndFailedCommandsAreNotSuccess() {
        let executor = QuickTimeExecutor()
        let controller = QuickTimeMediaController(executor: executor, processID: { 42 })
        let movie = QuickTimeMovie(processID: 42, windowID: 12, title: "Movie", isPlaying: true)
        executor.output = "missing"
        XCTAssertFalse(controller.toggle(movie))
        XCTAssertNil(controller.isPlaying(movie))
        executor.succeeded = false
        executor.output = "OK"
        XCTAssertFalse(controller.toggle(movie))
        XCTAssertNil(controller.scan())
    }

    func testEmptyScanDiffersFromFailureAndMalformedRowsAreIgnored() {
        let executor = QuickTimeExecutor()
        let controller = QuickTimeMediaController(executor: executor, processID: { 42 })
        executor.output = "OK\n"
        XCTAssertEqual(controller.scan(), [])
        executor.output = "OK\nbad\ttrue\tTitle\n12\tunknown\tTitle\n13\tfalse\tValid\n"
        XCTAssertEqual(controller.scan()?.map(\.windowID), [13])
        executor.output = nil
        XCTAssertNil(controller.scan())
    }

    func testMovieSelectionInvalidatesPlaybackObservation() {
        var status = PlaybackStatus()
        let old = PlaybackTargetContext(targetID: "quicktime", browserMediaID: nil,
                                        revision: 1, quickTimeMovieID: "42:12")
        let new = PlaybackTargetContext(targetID: "quicktime", browserMediaID: nil,
                                        revision: 2, quickTimeMovieID: "42:34")
        status.reset(for: old)
        let observation = status.observation(for: old)!
        status.reset(for: new)
        status.accept(true, from: observation)
        XCTAssertNil(status.isPlaying)
    }

    func testSeekAddsSignedSecondsInsideAppleScript() {
        let executor = QuickTimeExecutor()
        let controller = QuickTimeMediaController(executor: executor, processID: { 42 })
        let movie = QuickTimeMovie(processID: 42, windowID: 7, title: "Clip", isPlaying: true)
        executor.output = "OK"
        XCTAssertTrue(controller.seek(movie, by: -15))
        let script = executor.scripts.last ?? ""
        XCTAssertTrue(script.contains("window id 7"))
        XCTAssertTrue(script.contains("current time of targetMovie"))
        XCTAssertTrue(script.contains("(-15)"))
        XCTAssertFalse(script.contains("as text"))
    }

    func testSeekRefusesAMovieFromAnotherProcess() {
        let executor = QuickTimeExecutor()
        let controller = QuickTimeMediaController(executor: executor, processID: { 99 })
        let movie = QuickTimeMovie(processID: 42, windowID: 7, title: "Clip", isPlaying: true)
        XCTAssertFalse(controller.seek(movie, by: 15))
        XCTAssertTrue(executor.scripts.isEmpty)
    }
}

private final class QuickTimeExecutor: ScriptExecuting {
    var output: String?
    var succeeded = true
    var scripts: [String] = []

    func run(_ source: String) -> ScriptResult {
        scripts.append(source)
        return ScriptResult(output: output, succeeded: succeeded)
    }
}
