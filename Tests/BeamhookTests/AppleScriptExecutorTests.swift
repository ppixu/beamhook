import XCTest
import BeamhookKit
@testable import Beamhook

final class AppleScriptExecutorTests: XCTestCase {
    /// Beamhook runs scripts on several queues at once, and a browser scan asks
    /// many tabs in parallel. With `NSAppleScript`, concurrent runs share one
    /// AppleScript instance: they returned each other's results, or failed at
    /// once with -1751 — which is how a scan broke play/pause presses.
    func testConcurrentScriptsEachGetTheirOwnResult() {
        let executor = AppleScriptExecutor()
        let count = 8
        var results = [ScriptResult?](repeating: nil, count: count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: count) { index in
            let result = executor.run("delay 0.3\nreturn \"answer \(index)\"")
            lock.withLock { results[index] = result }
        }

        for index in 0..<count {
            XCTAssertEqual(results[index]?.succeeded, true, "script \(index)")
            XCTAssertEqual(results[index]?.output, "answer \(index)")
        }
    }

    func testFailingScriptReportsFailure() {
        let result = AppleScriptExecutor().run("error \"nope\"")

        XCTAssertFalse(result.succeeded)
        XCTAssertNil(result.output)
    }
}
