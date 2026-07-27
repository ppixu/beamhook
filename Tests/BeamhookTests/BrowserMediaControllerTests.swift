import XCTest
import BeamhookKit
@testable import Beamhook

final class BrowserMediaControllerTests: XCTestCase {
    func testCandidateIdentitySurvivesTabReordering() {
        let executor = RecordingScriptExecutor()
        let controller = BrowserMediaController(executor: executor)
        let sourceID = "550e8400-e29b-41d4-a716-446655440000"

        executor.output = scanOutput(window: 1, tab: 2, sourceID: sourceID)
        let first = controller.scan(.chrome).candidates.first
        executor.output = scanOutput(window: 4, tab: 9, sourceID: sourceID)
        let reordered = controller.scan(.chrome).candidates.first

        XCTAssertEqual(first?.id, reordered?.id)
        XCTAssertEqual(first?.id, "chrome:\(sourceID)")
    }

    func testInvalidPageSuppliedSourceIdentityIsRejected() {
        let executor = RecordingScriptExecutor()
        let controller = BrowserMediaController(executor: executor)
        executor.output = scanOutput(window: 1, tab: 1,
                                     sourceID: "'; do shell script \"bad\"; '")

        XCTAssertTrue(controller.scan(.safari).candidates.isEmpty)
    }

    func testSelectionResolvesSourceIdentityInsideBrowser() {
        let executor = RecordingScriptExecutor()
        let controller = BrowserMediaController(executor: executor)
        let candidate = makeCandidate()

        XCTAssertTrue(controller.select(candidate))

        let script = try? XCTUnwrap(executor.scripts.last)
        XCTAssertTrue(script?.contains(candidate.sourceID) == true)
        XCTAssertTrue(script?.contains("repeat with browserWindow in windows") == true)
        XCTAssertFalse(script?.contains("set targetTab to tab") == true)
    }

    func testVolumeWriteResolvesSourceIdentityInsideBrowser() {
        let executor = RecordingScriptExecutor()
        let controller = BrowserMediaController(executor: executor)
        let candidate = makeCandidate()

        XCTAssertTrue(controller.setVolume(75, for: candidate))

        let script = try? XCTUnwrap(executor.scripts.last)
        XCTAssertTrue(script?.contains(candidate.sourceID) == true)
        XCTAssertTrue(script?.contains("x.volume = 75 / 100") == true)
        XCTAssertTrue(script?.contains("targetFound is false") == true)
    }

    func testPlayPauseResolvesExactSourceIdentityInsideBrowser() {
        let executor = RecordingScriptExecutor()
        let controller = BrowserMediaController(executor: executor)
        let candidate = makeCandidate()

        XCTAssertTrue(controller.togglePlayPause(candidate))

        let script = try? XCTUnwrap(executor.scripts.last)
        XCTAssertTrue(script?.contains(candidate.sourceID) == true)
        XCTAssertTrue(script?.contains("repeat with browserWindow in windows") == true)
        XCTAssertTrue(script?.contains("p.el.pause()") == true)
        XCTAssertTrue(script?.contains("p.el.play()") == true)
        XCTAssertFalse(script?.contains("set targetTab to tab") == true)
    }

    func testCallTabIsListedButCannotBeDrivenByTransport() {
        let executor = RecordingScriptExecutor()
        let controller = BrowserMediaController(executor: executor)
        executor.output = scanOutput(window: 1, tab: 1,
                                     sourceID: "550e8400-e29b-41d4-a716-446655440000",
                                     live: true)

        let candidates = controller.scan(.chrome).candidates

        // A meeting keeps its row — the volume slider is the point — but must
        // never offer transport: pausing a live MediaStream freezes the call.
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates.first?.supportsTransport, false)
    }

    func testRegularMediaTabSupportsTransport() {
        let executor = RecordingScriptExecutor()
        let controller = BrowserMediaController(executor: executor)
        executor.output = scanOutput(window: 1, tab: 1,
                                     sourceID: "550e8400-e29b-41d4-a716-446655440000")

        XCTAssertEqual(controller.scan(.chrome).candidates.first?.supportsTransport, true)
    }

    func testEachSourceCarriesItsOwnTransportCapability() {
        let executor = RecordingScriptExecutor()
        let controller = BrowserMediaController(executor: executor)
        let meeting = "550e8400-e29b-41d4-a716-446655440000"
        let video = "6ba7b810-9dad-11d1-80b4-00c04fd430c8"
        executor.output = """
        OK
        \(row(window: 1, tab: 1, sourceID: meeting, live: true))
        \(row(window: 1, tab: 2, sourceID: video, live: false))
        """

        let candidates = controller.scan(.safari).candidates

        XCTAssertEqual(candidates.count, 2)
        XCTAssertEqual(candidates.first(where: { $0.sourceID == meeting })?.supportsTransport,
                       false)
        XCTAssertEqual(candidates.first(where: { $0.sourceID == video })?.supportsTransport,
                       true)
    }

    func testTransportScriptsDeclineALiveStream() {
        let executor = RecordingScriptExecutor()
        let controller = BrowserMediaController(executor: executor)

        _ = controller.togglePlayPause(makeCandidate())
        let playPause = executor.scripts.last
        _ = controller.setVolume(30, for: makeCandidate())
        let volume = executor.scripts.last

        // The backstop behind the hidden UI control: even a stale selection that
        // reaches a call tab must refuse to touch its transport. Volume, which is
        // meaningful on a call, carries no such guard and writes the whole group.
        XCTAssertTrue(playPause?.contains("if (!p || p.live) return 'NO'") == true)
        XCTAssertTrue(volume?.contains("p.group.forEach") == true)
        XCTAssertFalse(volume?.contains("p.live") == true)
    }

    private func makeCandidate() -> BrowserMediaCandidate {
        BrowserMediaCandidate(
            browser: .chrome,
            sourceID: "550e8400-e29b-41d4-a716-446655440000",
            title: "Test video",
            artist: "Test artist",
            isPlaying: true,
            isSelected: false,
            supportsTransport: true,
            volume: 50
        )
    }

    private func scanOutput(window: Int, tab: Int, sourceID: String,
                            live: Bool = false) -> String {
        """
        OK
        \(row(window: window, tab: tab, sourceID: sourceID, live: live))
        """
    }

    private func row(window: Int, tab: Int, sourceID: String, live: Bool) -> String {
        let escapedID = sourceID
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return """
        \(window)\t\(tab)\t{"sourceID":"\(escapedID)","title":"Test","artist":"","playing":true,"selected":false,"live":\(live),"volume":50}
        """
    }
}

private final class RecordingScriptExecutor: ScriptExecuting {
    var scripts: [String] = []
    var output: String? = "true"
    var succeeds = true

    func run(_ source: String) -> ScriptResult {
        scripts.append(source)
        return ScriptResult(output: output, succeeded: succeeds)
    }
}
