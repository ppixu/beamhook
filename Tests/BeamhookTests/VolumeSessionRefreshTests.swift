import XCTest
import BeamhookKit
@testable import Beamhook

@MainActor
final class VolumeSessionRefreshTests: XCTestCase {
    /// Seed a real AppState session without opening windows or starting scans.
    /// These tests must run with runtime exclusivity checks enabled (Debug).
    private func withState(_ body: (AppState, BrowserMediaCandidate) -> Void) {
        let defaults = UserDefaults.standard
        let keys = [PerAppMutePreference.enabledKey, PerAppMutePreference.mutedAppsKey,
                    PerAppMutePreference.volumesKey, "selectedTargetAppID"]
        let saved = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, saved) {
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }
        let state = AppState()
        state.perAppMuteEnabled = false
        state.targetManager.selectedTargetID = nil
        state.selectedTargetID = nil
        let tab = BrowserMediaCandidate(browser: .safari, sourceID: "refresh-test",
                                        windowIndex: 1, tabIndex: 1, title: "Test video",
                                        artist: "", host: "example.com", isPlaying: false,
                                        isSelected: false, supportsTransport: true, volume: 40)
        state.activeBrowserMediaCandidates = [tab]
        defer { state.volumeSession = nil }
        body(state, tab)
    }

    private func session(for tab: BrowserMediaCandidate) -> VolumeSourceList {
        let parent = VolumeSourceEntry(source: .app(bundleID: tab.browser.bundleID), name: "Safari")
        return VolumeSourceList(target: nil, apps: [parent], tabs: [
            VolumeSourceEntry(source: .browserTab(id: tab.id), name: "Earlier title",
                              parentSource: parent.source),
        ])
    }

    func testCompactSessionRefreshReadsStateWithoutOverlappingWrite() {
        withState { state, tab in
            var list = session(for: tab)
            list.select(.browserTab(id: tab.id))
            state.volumeSession = list

            // This is the same refresh method used after background audio and
            // browser scans. Mutating the property while computing its source
            // arguments aborts here, even though it compiles successfully.
            state.replaceVolumeSessionSources(audible: [tab.browser.bundleID])
            XCTAssertEqual(state.volumeSession?.selected?.source, .browserTab(id: tab.id))
            XCTAssertEqual(state.volumeSession?.selected?.name, tab.label)
            XCTAssertEqual(state.volumeSession?.showsAllSources, false)
            XCTAssertFalse(state.replaceVolumeSessionSources(audible: [tab.browser.bundleID]),
                           "An unchanged refresh should not trigger another writeback")
        }
    }

    func testExpandedSessionRefreshPreservesSelectionAndExpansion() {
        withState { state, tab in
            var list = session(for: tab)
            list.selectNext()
            XCTAssertTrue(list.showsAllSources)
            state.volumeSession = list

            state.replaceVolumeSessionSources(audible: [tab.browser.bundleID])
            XCTAssertEqual(state.volumeSession?.selected?.source, .browserTab(id: tab.id))
            XCTAssertEqual(state.volumeSession?.selected?.name, tab.label)
            XCTAssertEqual(state.volumeSession?.showsAllSources, true)
        }
    }

    func testRefreshKeepsAShownRunningAppUntilTheSessionEnds() {
        withState { state, tab in
            // Finder is always running but never plays, so only the session keeps it.
            let finder = VolumeSourceEntry(source: .app(bundleID: "com.apple.finder"), name: "Finder")
            state.volumeSession = VolumeSourceList(target: nil, apps: [finder], tabs: [])
            state.replaceVolumeSessionSources(audible: [])
            XCTAssertTrue(state.volumeSession?.entries.contains { $0.source == finder.source } == true,
                          "A row on screen must not disappear while the overlay is up")

            let gone = VolumeSourceEntry(source: .app(bundleID: "com.example.beamhook-not-running"),
                                         name: "Quit")
            state.volumeSession = VolumeSourceList(target: nil, apps: [gone], tabs: [])
            state.replaceVolumeSessionSources(audible: [])
            XCTAssertFalse(state.volumeSession?.entries.contains { $0.source == gone.source } == true,
                           "A quit app still leaves the list")
        }
    }

    func testRefreshDoesNotReopenClosedSession() {
        withState { state, tab in
            XCTAssertNil(state.volumeSession)
            XCTAssertFalse(state.replaceVolumeSessionSources(audible: [tab.browser.bundleID]))
            XCTAssertNil(state.volumeSession)
        }
    }
}
