import XCTest
import BeamhookKit
@testable import Beamhook

@MainActor
final class MenuSourceSelectionTests: XCTestCase {
    private func tab(_ sourceID: String) -> BrowserMediaCandidate {
        BrowserMediaCandidate(browser: .safari, sourceID: sourceID, windowIndex: 2,
                              tabIndex: 3, title: sourceID, artist: "", host: "example.com",
                              isPlaying: true, isSelected: false,
                              supportsTransport: true, volume: 42)
    }

    private func restoreSelection(_ value: Any?) {
        if let value { UserDefaults.standard.set(value, forKey: "selectedTargetAppID") }
        else { UserDefaults.standard.removeObject(forKey: "selectedTargetAppID") }
    }

    func testHookingAnUnselectedBrowsersTabKeepsTheExactSource() async {
        let saved = UserDefaults.standard.object(forKey: "selectedTargetAppID")
        defer { restoreSelection(saved) }
        let executor = MenuSelectionExecutor()
        let state = AppState(browserMediaController: BrowserMediaController(executor: executor))
        state.setTarget(BuiltInApps.spotify.id, showConfirmation: false)
        let first = tab("first-page"), chosen = tab("chosen-page")
        state.activeBrowserMediaCandidates = [first, chosen]

        let succeeded = await state.hookBrowserMedia(chosen, showConfirmation: false)

        XCTAssertTrue(succeeded)
        XCTAssertEqual(state.selectedTargetID, "safari-youtube")
        XCTAssertEqual(state.targetManager.selectedTargetID, "safari-youtube")
        XCTAssertEqual(state.selectedBrowserMediaID, chosen.id)
        XCTAssertTrue(state.browserMediaCandidates.contains(chosen))
        XCTAssertEqual(state.browserMediaInjectionAvailable, true)
        XCTAssertEqual(state.currentVolume(of: .hookedTarget), 42)
        XCTAssertTrue(executor.script.contains(chosen.sourceID))
    }

    func testHookedTabVolumeUsesOneTargetedWriteAndAccumulatesCachedSteps() async {
        let saved = UserDefaults.standard.object(forKey: "selectedTargetAppID")
        defer { restoreSelection(saved) }
        let executor = MenuSelectionExecutor()
        let state = AppState(browserMediaController: BrowserMediaController(executor: executor))
        let chosen = tab("volume-page")
        state.activeBrowserMediaCandidates = [chosen]
        let hooked = await state.hookBrowserMedia(chosen, showConfirmation: false)
        XCTAssertTrue(hooked)
        executor.scripts = []

        let first = await state.changeVolume(of: .hookedTarget, session: 999) { $0 + 6 }
        let second = await state.changeVolume(of: .hookedTarget, session: 999) { $0 + 6 }

        XCTAssertEqual(first?.previous, 42)
        XCTAssertEqual(first?.volume, 48)
        XCTAssertEqual(second?.previous, 48)
        XCTAssertEqual(second?.volume, 54)
        XCTAssertEqual(state.currentVolume(of: .hookedTarget), 54)
        XCTAssertEqual(executor.scripts.count, 2)
        XCTAssertTrue(executor.scripts.allSatisfy {
            $0.contains("tab 3 of window 2") && $0.contains(chosen.sourceID)
        })
    }

    func testFailedHookedTabVolumeWritePreservesCachedLevel() async {
        let saved = UserDefaults.standard.object(forKey: "selectedTargetAppID")
        defer { restoreSelection(saved) }
        let executor = MenuSelectionExecutor()
        let state = AppState(browserMediaController: BrowserMediaController(executor: executor))
        let chosen = tab("failed-volume")
        state.activeBrowserMediaCandidates = [chosen]
        let hooked = await state.hookBrowserMedia(chosen, showConfirmation: false)
        XCTAssertTrue(hooked)
        executor.succeeds = false

        let change = await state.changeVolume(of: .hookedTarget, session: 999) { $0 + 6 }

        XCTAssertNil(change)
        XCTAssertEqual(state.currentVolume(of: .hookedTarget), 42)
    }

    func testFailedTabSelectionDoesNotMoveTheHook() async {
        let saved = UserDefaults.standard.object(forKey: "selectedTargetAppID")
        defer { restoreSelection(saved) }
        let executor = MenuSelectionExecutor(succeeds: false)
        let state = AppState(browserMediaController: BrowserMediaController(executor: executor))
        state.setTarget(BuiltInApps.spotify.id, showConfirmation: false)

        let succeeded = await state.hookBrowserMedia(tab("closed-page"), showConfirmation: false)

        XCTAssertFalse(succeeded)
        XCTAssertEqual(state.selectedTargetID, BuiltInApps.spotify.id)
        XCTAssertNil(state.selectedBrowserMediaID)
    }

    func testUnhookWhileTabSelectionIsPendingWinsOverItsLateReply() async {
        let saved = UserDefaults.standard.object(forKey: "selectedTargetAppID")
        defer { restoreSelection(saved) }
        let started = expectation(description: "Browser selection began")
        let gate = DispatchSemaphore(value: 0)
        let executor = MenuSelectionExecutor {
            started.fulfill()
            _ = gate.wait(timeout: .now() + 5)
        }
        let state = AppState(browserMediaController: BrowserMediaController(executor: executor))
        state.setTarget(BuiltInApps.spotify.id, showConfirmation: false)
        let candidate = tab("slow-page")
        let selection = Task { await state.hookBrowserMedia(candidate, showConfirmation: false) }
        await fulfillment(of: [started], timeout: 2)
        state.setTarget(nil, showConfirmation: false)
        gate.signal()

        let succeeded = await selection.value

        XCTAssertFalse(succeeded)
        XCTAssertNil(state.selectedTargetID)
        XCTAssertNil(state.targetManager.selectedTargetID)
    }

    func testQuitTargetRemainsInCompactMenuAndIsNotDuplicated() {
        let state = AppState()
        let bundleID = "com.example.beamhook-not-running"
        var definition = BuiltInApps.spotify
        definition.id = "menu-test-target"
        definition.bundleID = bundleID
        definition.displayName = "Quit player"
        state.availableApps.append(definition)
        state.selectedTargetID = definition.id
        XCTAssertFalse(state.isRunning(bundleID: bundleID))
        XCTAssertEqual(state.menuAppRows([]).first?.bundleID, bundleID)

        let observed = PlayingApp(id: bundleID, displayName: "Process name", bundleID: bundleID)
        let rows = state.menuAppRows([observed, observed])
        XCTAssertEqual(rows.filter { $0.bundleID == bundleID }.count, 1)
        XCTAssertEqual(rows.first?.displayName, "Quit player")
    }
    func testRecentFilterHidesUnobservedAppsAndExpiresAfterTwoHours() {
        let state = AppState()
        let now = Date(timeIntervalSince1970: 2_000_000)
        let recent = PlayingApp(id: "recent", displayName: "Recent", bundleID: "com.example.recent")
        let idle = PlayingApp(id: "idle", displayName: "Idle", bundleID: "com.example.idle")
        XCTAssertTrue(state.recentAppRows([recent, idle], now: now).isEmpty)
        state.recordAppPlayback([recent.bundleID], now: now)
        XCTAssertEqual(state.recentAppRows([recent, idle], now: now.addingTimeInterval(7199)), [recent])
        XCTAssertTrue(state.recentAppRows([recent, idle], now: now.addingTimeInterval(7200)).isEmpty)
    }

    func testTurnedDownAppStaysInShortlistWithoutPlaybackHistory() {
        let state = AppState()
        let quiet = PlayingApp(id: "quiet", displayName: "Quiet", bundleID: "com.example.quiet")
        let loud = PlayingApp(id: "loud", displayName: "Loud", bundleID: "com.example.loud")
        state.volumeByBundle[quiet.bundleID] = AppState.quietVolumeThreshold - 1
        state.volumeByBundle[loud.bundleID] = AppState.quietVolumeThreshold
        XCTAssertEqual(state.recentAppRows([quiet, loud]), [quiet])
        state.volumeByBundle[quiet.bundleID] = 0
        XCTAssertEqual(state.recentAppRows([quiet, loud]), [quiet])
    }

    func testDisplayedPausedTabKeepsBrowserInCompactMenu() {
        let state = AppState()
        let safari = PlayingApp(id: "com.apple.Safari", displayName: "Safari", bundleID: "com.apple.Safari")
        let tab = BrowserMediaCandidate(browser: .safari, sourceID: "selected-paused", windowIndex: 1,
            tabIndex: 1, title: "Video", artist: "", host: "example.com", isPlaying: false,
            isSelected: true, supportsTransport: true, volume: 50)
        state.activeBrowserMediaCandidates = [tab]
        XCTAssertEqual(state.recentAppRows([safari]), [safari])
        state.activeBrowserMediaCandidates = []
        if state.targetManager.targetBundleID != safari.bundleID {
            XCTAssertTrue(state.recentAppRows([safari]).isEmpty)
        }
    }

}

private final class MenuSelectionExecutor: ScriptExecuting {
    var succeeds: Bool
    let beforeReply: () -> Void
    private(set) var script = ""
    var scripts: [String] = []

    init(succeeds: Bool = true, beforeReply: @escaping () -> Void = {}) {
        self.succeeds = succeeds
        self.beforeReply = beforeReply
    }

    func run(_ source: String) -> ScriptResult {
        script = source
        scripts.append(source)
        beforeReply()
        return ScriptResult(output: succeeds ? "true" : nil, succeeded: succeeds)
    }


}
