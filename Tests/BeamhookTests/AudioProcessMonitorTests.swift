import AppKit
import Combine
import XCTest
@testable import Beamhook

@available(macOS 14.2, *)
@MainActor
final class AudioProcessMonitorTests: XCTestCase {
    private let app = PlayingApp(id: "test", displayName: "Test", bundleID: "test")

    func testSlowScanLeavesMainQueueFreeAndCoalescesRefreshes() async {
        let started = expectation(description: "Scan started off main")
        started.assertForOverFulfill = true
        let published = expectation(description: "Snapshot published on main")
        let responsive = expectation(description: "Main queue responds during scan")
        let gate = DispatchSemaphore(value: 0)
        let app = app
        let monitor = AudioProcessMonitor {
            XCTAssertFalse(Thread.isMainThread)
            started.fulfill()
            _ = gate.wait(timeout: .now() + 3)
            return [app]
        }
        defer { gate.signal(); monitor.stop() }
        let subscription = monitor.$playingApps.dropFirst().sink { apps in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(apps, [app])
            published.fulfill()
        }
        defer { subscription.cancel() }

        monitor.start()
        for _ in 0..<10 { monitor.refresh() }
        DispatchQueue.main.async { responsive.fulfill() }
        await fulfillment(of: [started, responsive], timeout: 1)
        XCTAssertTrue(monitor.playingApps.isEmpty)
        gate.signal()
        await fulfillment(of: [published], timeout: 1)
    }

    func testClosingMenuDiscardsPendingSnapshot() async {
        let started = expectation(description: "Scan started")
        let published = expectation(description: "Closed monitor must not publish")
        published.isInverted = true
        let gate = DispatchSemaphore(value: 0)
        let app = app
        let monitor = AudioProcessMonitor {
            started.fulfill()
            _ = gate.wait(timeout: .now() + 3)
            return [app]
        }
        defer { gate.signal(); monitor.stop() }
        let subscription = monitor.$playingApps.dropFirst().sink { _ in published.fulfill() }
        defer { subscription.cancel() }

        monitor.start()
        await fulfillment(of: [started], timeout: 1)
        monitor.stop()
        gate.signal()
        await fulfillment(of: [published], timeout: 0.2)
        XCTAssertTrue(monitor.playingApps.isEmpty)
    }

    func testReopeningDuringScanPublishesOnlyFreshSnapshot() async {
        let started = expectation(description: "Old scan started")
        let published = expectation(description: "New session published")
        published.assertForOverFulfill = true
        let gate = DispatchSemaphore(value: 0)
        let calls = ScanCounter()
        let old = app
        let fresh = PlayingApp(id: "fresh", displayName: "Fresh", bundleID: "fresh")
        let monitor = AudioProcessMonitor {
            if calls.next() == 1 {
                started.fulfill()
                _ = gate.wait(timeout: .now() + 3)
                return [old]
            }
            return [fresh]
        }
        defer { gate.signal(); monitor.stop() }
        let subscription = monitor.$playingApps.dropFirst().sink { apps in
            XCTAssertEqual(apps, [fresh], "Never publish the old menu session's scan")
            published.fulfill()
        }
        defer { subscription.cancel() }

        monitor.start()
        await fulfillment(of: [started], timeout: 1)
        monitor.stop()
        monitor.start()
        gate.signal()
        await fulfillment(of: [published], timeout: 1)
        XCTAssertEqual(monitor.playingApps, [fresh])
    }

    private final class ScanCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        func next() -> Int {
            lock.lock()
            defer { lock.unlock() }
            value += 1
            return value
        }
    }
}
