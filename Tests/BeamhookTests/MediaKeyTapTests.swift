import XCTest
@testable import Beamhook

final class MediaKeyTapTests: XCTestCase {
    func testRoutingFlagsSupportConcurrentReadersAndWriters() {
        let tap = MediaKeyTap { _ in }

        DispatchQueue.concurrentPerform(iterations: 1_000) { index in
            if index.isMultiple(of: 2) {
                tap.transportKeysHijacked = index.isMultiple(of: 4)
                tap.volumeKeysHijacked = index.isMultiple(of: 6)
            } else {
                _ = tap.transportKeysHijacked
                _ = tap.volumeKeysHijacked
            }
        }

        tap.transportKeysHijacked = true
        tap.volumeKeysHijacked = false
        XCTAssertTrue(tap.transportKeysHijacked)
        XCTAssertFalse(tap.volumeKeysHijacked)
    }
}
