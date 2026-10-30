import XCTest
import BeamhookKit
@testable import Beamhook

final class AppleScriptExecutorTests: XCTestCase {
    /// Beamhook runs scripts on several queues at once. Run unguarded, concurrent
    /// `NSAppleScript`s share one AppleScript instance: they returned each
    /// other's results, or failed at once with -1751 — which is how a scan broke
    /// play/pause presses.
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

    /// 1.5.3 let scripts execute inside the interpreter at the same time, one
    /// OSAKit instance per thread, and crashed on a corrupted heap. Scripts from
    /// every queue now take turns.
    func testScriptsFromDifferentThreadsRunOneAtATime() {
        let executor = AppleScriptExecutor()
        let count = 4
        let start = Date()
        DispatchQueue.concurrentPerform(iterations: count) { _ in
            _ = executor.run("delay 0.25\nreturn \"done\"")
        }

        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), Double(count) * 0.25)
    }

    func testFailingScriptReportsFailure() {
        let result = AppleScriptExecutor().run("error \"nope\"")

        XCTAssertFalse(result.succeeded)
        XCTAssertNil(result.output)
    }
}
