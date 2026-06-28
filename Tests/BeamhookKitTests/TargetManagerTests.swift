import XCTest
@testable import BeamhookKit

final class TargetManagerTests: XCTestCase {
    final class MockResolver: MediaAppResolver {
        var apps: [String: MockMediaApp] = [:]
        func app(withID id: String) -> MediaApp? { apps[id] }
        func allApps() -> [MediaApp] { Array(apps.values) }
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "TargetManagerTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    func testSelectionPersists() {
        let defaults = makeDefaults()
        let resolver = MockResolver()
        let tm = TargetManager(defaults: defaults, resolver: resolver)
        tm.selectedTargetID = "spotify"

        let tm2 = TargetManager(defaults: defaults, resolver: resolver)
        XCTAssertEqual(tm2.selectedTargetID, "spotify")
    }

    func testHandleForwardsToRunningTarget() {
        let resolver = MockResolver()
        let spotify = MockMediaApp(id: "spotify", isRunning: true)
        resolver.apps["spotify"] = spotify
        let tm = TargetManager(defaults: makeDefaults(), resolver: resolver)
        tm.selectedTargetID = "spotify"

        tm.handle(.playPause)
        XCTAssertEqual(spotify.performedCommands, [.playPause])
    }

    func testHandleNoOpWhenTargetNotRunning() {
        let resolver = MockResolver()
        let spotify = MockMediaApp(id: "spotify", isRunning: false)
        resolver.apps["spotify"] = spotify
        let tm = TargetManager(defaults: makeDefaults(), resolver: resolver)
        tm.selectedTargetID = "spotify"

        tm.handle(.playPause)
        XCTAssertTrue(spotify.performedCommands.isEmpty)
    }

    func testHandleNoOpWhenNoTargetSelected() {
        let resolver = MockResolver()
        let spotify = MockMediaApp(id: "spotify", isRunning: true)
        resolver.apps["spotify"] = spotify
        let tm = TargetManager(defaults: makeDefaults(), resolver: resolver)

        tm.handle(.playPause)
        XCTAssertTrue(spotify.performedCommands.isEmpty)
    }

    func testHandleNoOpWhenTargetIDUnresolvable() {
        let resolver = MockResolver()
        let spotify = MockMediaApp(id: "spotify", isRunning: true)
        resolver.apps["spotify"] = spotify
        let tm = TargetManager(defaults: makeDefaults(), resolver: resolver)
        tm.selectedTargetID = "defunct-app"   // not registered in the resolver
        tm.handle(.playPause)
        XCTAssertTrue(spotify.performedCommands.isEmpty)
    }

    func testHandleIgnoresVolumeKeys() {
        let resolver = MockResolver()
        let spotify = MockMediaApp(id: "spotify", isRunning: true)
        resolver.apps["spotify"] = spotify
        let tm = TargetManager(defaults: makeDefaults(), resolver: resolver)
        tm.selectedTargetID = "spotify"

        tm.handle(.volumeUp)
        XCTAssertTrue(spotify.performedCommands.isEmpty)
    }
}
