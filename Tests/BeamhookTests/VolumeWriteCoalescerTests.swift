import XCTest
@testable import Beamhook

@MainActor
final class VolumeWriteCoalescerTests: XCTestCase {
    func testDragSendsBeforeReleaseAndKeepsOnlyLatestPendingValue() async {
        let writer = VolumeWriteCoalescer()
        let started = expectation(description: "First drag value sent immediately")
        let finished = expectation(description: "Final drag value sent")
        var resume: CheckedContinuation<Void, Never>?
        var values: [Int] = []
        writer.submit(source: "tab:a") {
            values.append(10)
            await withCheckedContinuation { continuation in
                resume = continuation
                started.fulfill()
            }
        }
        await fulfillment(of: [started], timeout: 2)
        for value in [20, 40, 90] {
            writer.submit(source: "tab:a") {
                values.append(value)
                if value == 90 { finished.fulfill() }
            }
        }
        XCTAssertEqual(values, [10])
        resume?.resume()
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertEqual(values, [10, 90])

        let next = expectation(description: "Later drag starts again")
        writer.submit(source: "tab:a") { values.append(50); next.fulfill() }
        await fulfillment(of: [next], timeout: 2)
        XCTAssertEqual(values, [10, 90, 50])
    }

    func testDifferentSourcesKeepTheirOwnFinalValues() async {
        let writer = VolumeWriteCoalescer()
        let done = expectation(description: "Both sources written")
        done.expectedFulfillmentCount = 2
        var values: [String: Int] = [:]
        writer.submit(source: "app:a") { XCTFail("Superseded before starting") }
        writer.submit(source: "app:a") { values["a"] = 25; done.fulfill() }
        writer.submit(source: "tab:b") { values["b"] = 75; done.fulfill() }
        await fulfillment(of: [done], timeout: 2)
        XCTAssertEqual(values, ["a": 25, "b": 75])
    }
}
