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
        XCTAssertTrue(script?.contains("m.pause()") == true)
        XCTAssertTrue(script?.contains("m.play()") == true)
        XCTAssertFalse(script?.contains("set targetTab to tab") == true)
    }

    private func makeCandidate() -> BrowserMediaCandidate {
        BrowserMediaCandidate(
            browser: .chrome,
            sourceID: "550e8400-e29b-41d4-a716-446655440000",
            title: "Test video",
            artist: "Test artist",
            isPlaying: true,
            isSelected: false,
            volume: 50
        )
    }

    private func scanOutput(window: Int, tab: Int, sourceID: String) -> String {
        let escapedID = sourceID
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return """
        OK
        \(window)\t\(tab)\t{"sourceID":"\(escapedID)","title":"Test","artist":"","playing":true,"selected":false,"volume":50}
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
