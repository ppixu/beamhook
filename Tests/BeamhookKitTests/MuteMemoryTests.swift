import XCTest
@testable import BeamhookKit

final class MuteMemoryTests: XCTestCase {
    func testAudibleTogglesToZero() {
        XCTAssertEqual(MuteMemory.toggled(from: 40, restore: 70), 0)
    }

    func testSilentTogglesToRestore() {
        XCTAssertEqual(MuteMemory.toggled(from: 0, restore: 70), 70)
    }

    func testRestoreFallsBackToFiftyWhenNothingRemembered() {
        let memory = MuteMemory()
        XCTAssertEqual(MuteMemory.fallbackRestore, 50)
        XCTAssertEqual(memory.restoreVolume(for: "app:x"), 50)
    }

    func testMuteThenUnmuteRestoresThePreviousVolume() {
        var memory = MuteMemory()
        memory.record(sourceID: "app:x", previous: 40, new: 0)
        XCTAssertEqual(memory.restoreVolume(for: "app:x"), 40)
        memory.record(sourceID: "app:x", previous: 0, new: 40)
        XCTAssertEqual(memory.restoreVolume(for: "app:x"), 50, "an unmute forgets the value")
    }

    func testSourcesAreRememberedSeparately() {
        var memory = MuteMemory()
        memory.record(sourceID: "app:x", previous: 30, new: 0)
        memory.record(sourceID: "tab:y", previous: 80, new: 0)
        XCTAssertEqual(memory.restoreVolume(for: "app:x"), 30)
        XCTAssertEqual(memory.restoreVolume(for: "tab:y"), 80)
    }

    func testMutingAnAlreadySilentSourceRemembersNothing() {
        var memory = MuteMemory()
        memory.record(sourceID: "app:x", previous: 0, new: 0)
        XCTAssertEqual(memory.restoreVolume(for: "app:x"), 50)
    }
}
