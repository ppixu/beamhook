import XCTest
@testable import BeamhookKit

final class VolumeSourceListTests: XCTestCase {
    private let target = VolumeSourceEntry(source: .hookedTarget, name: "Spotify")
    private func app(_ id: String) -> VolumeSourceEntry {
        VolumeSourceEntry(source: .app(bundleID: id), name: id)
    }
    private func tab(_ id: String) -> VolumeSourceEntry {
        VolumeSourceEntry(source: .browserTab(id: id), name: id)
    }

    func testIdsAreDistinctPerKind() {
        XCTAssertEqual(VolumeSource.hookedTarget.id, "target")
        XCTAssertEqual(VolumeSource.app(bundleID: "x").id, "app:x")
        XCTAssertEqual(VolumeSource.browserTab(id: "x").id, "tab:x")
    }

    func testOrderIsTargetThenAppsThenTabsAndStartsOnTarget() {
        let list = VolumeSourceList(target: target, apps: [app("music")], tabs: [tab("yt")])
        XCTAssertEqual(list.entries.map(\.name), ["Spotify", "music", "yt"])
        XCTAssertEqual(list.selectedIndex, 0)
        XCTAssertEqual(list.selected, target)
    }

    func testCapsAtSixRowsDroppingTabsFirst() {
        let list = VolumeSourceList(target: target,
                                    apps: [app("a1"), app("a2"), app("a3")],
                                    tabs: [tab("t1"), tab("t2"), tab("t3")])
        XCTAssertEqual(VolumeSourceList.maxRows, 6)
        XCTAssertEqual(list.entries.map(\.name), ["Spotify", "a1", "a2", "a3", "t1", "t2"])
    }

    func testDuplicateSourcesAreDropped() {
        let list = VolumeSourceList(target: target, apps: [app("a"), app("a")], tabs: [])
        XCTAssertEqual(list.entries.count, 2)
    }

    func testSelectionWrapsBothWays() {
        var list = VolumeSourceList(target: target, apps: [app("a")], tabs: [tab("t")])
        list.selectPrevious()
        XCTAssertEqual(list.selected?.name, "t")
        list.selectNext()
        XCTAssertEqual(list.selected?.name, "Spotify")
        list.selectNext()
        XCTAssertEqual(list.selected?.name, "a")
    }

    func testEmptyListIsInert() {
        var list = VolumeSourceList(target: nil, apps: [], tabs: [])
        list.selectNext()
        list.selectPrevious()
        XCTAssertNil(list.selected)
        XCTAssertEqual(list.selectedIndex, 0)
    }

    func testReplaceKeepsSelectionBySourceWhenTabsArrive() {
        var list = VolumeSourceList(target: target, apps: [app("a"), app("b")], tabs: [])
        list.selectNext()
        list.selectNext()   // "b"
        list.replace(target: target, apps: [app("a"), app("b")], tabs: [tab("t")])
        XCTAssertEqual(list.selected?.name, "b")
        XCTAssertEqual(list.entries.count, 4)
    }

    func testReplaceFollowsSelectionWhenRowsReorder() {
        var list = VolumeSourceList(target: target, apps: [app("a"), app("b")], tabs: [])
        list.selectNext()   // "a"
        list.replace(target: target, apps: [app("b"), app("a")], tabs: [])
        XCTAssertEqual(list.selected?.name, "a")
        XCTAssertEqual(list.selectedIndex, 2)
    }

    func testReplaceFallsBackToNeighbourWhenSelectionVanishes() {
        var list = VolumeSourceList(target: target, apps: [app("a"), app("b")], tabs: [])
        list.selectPrevious()   // "b", index 2
        list.replace(target: target, apps: [app("a")], tabs: [])
        XCTAssertEqual(list.selectedIndex, 1)
        XCTAssertEqual(list.selected?.name, "a")
    }

    func testReplaceWithNothingResetsToZero() {
        var list = VolumeSourceList(target: target, apps: [app("a")], tabs: [])
        list.selectNext()
        list.replace(target: nil, apps: [], tabs: [])
        XCTAssertEqual(list.selectedIndex, 0)
        XCTAssertNil(list.selected)
    }
}
