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

    private func makeManager(resolver: MediaAppResolver, defaults: UserDefaults? = nil,
                             volumeStep: Int = 6) -> TargetManager {
        TargetManager(defaults: defaults ?? makeDefaults(), resolver: resolver,
                      runner: InlineScriptRunner(), volumeStep: volumeStep)
    }

    func testSelectionPersists() {
        let defaults = makeDefaults()
        let resolver = MockResolver()
        let tm = makeManager(resolver: resolver, defaults: defaults)
        tm.selectedTargetID = "spotify"

        let tm2 = makeManager(resolver: resolver, defaults: defaults)
        XCTAssertEqual(tm2.selectedTargetID, "spotify")
    }

    func testNoSelectionPersists() {
        let defaults = makeDefaults()
        let resolver = MockResolver()
        let tm = makeManager(resolver: resolver, defaults: defaults)
        tm.selectedTargetID = nil

        let tm2 = makeManager(resolver: resolver, defaults: defaults)
        XCTAssertTrue(tm2.hasSavedSelection)
        XCTAssertNil(tm2.selectedTargetID)
    }

    func testFreshManagerHasNoSavedSelection() {
        let defaults = makeDefaults()
        let tm = makeManager(resolver: MockResolver(), defaults: defaults)

        XCTAssertFalse(tm.hasSavedSelection)
        XCTAssertNil(tm.selectedTargetID)
    }

    func testRouteForwardsToRunningTarget() async {
        let resolver = MockResolver()
        let spotify = MockMediaApp(id: "spotify", isRunning: true)
        resolver.apps["spotify"] = spotify
        let tm = makeManager(resolver: resolver)
        tm.selectedTargetID = "spotify"

        await tm.route(.playPause)
        XCTAssertEqual(spotify.performedCommands, [.playPause])
    }

    func testRouteNoOpWhenTargetNotRunning() async {
        let resolver = MockResolver()
        let spotify = MockMediaApp(id: "spotify", isRunning: false)
        resolver.apps["spotify"] = spotify
        let tm = makeManager(resolver: resolver)
        tm.selectedTargetID = "spotify"

        await tm.route(.playPause)
        XCTAssertTrue(spotify.performedCommands.isEmpty)
    }

    func testRouteNoOpWhenNoTargetSelected() async {
        let resolver = MockResolver()
        let spotify = MockMediaApp(id: "spotify", isRunning: true)
        resolver.apps["spotify"] = spotify
        let tm = makeManager(resolver: resolver)

        await tm.route(.playPause)
        XCTAssertTrue(spotify.performedCommands.isEmpty)
    }

    func testRouteNoOpWhenTargetIDUnresolvable() async {
        let resolver = MockResolver()
        let spotify = MockMediaApp(id: "spotify", isRunning: true)
        resolver.apps["spotify"] = spotify
        let tm = makeManager(resolver: resolver)
        tm.selectedTargetID = "defunct-app"   // not registered in the resolver
        await tm.route(.playPause)
        XCTAssertTrue(spotify.performedCommands.isEmpty)
    }

    func testRouteIgnoresVolumeKeys() async {
        let resolver = MockResolver()
        let spotify = MockMediaApp(id: "spotify", isRunning: true)
        resolver.apps["spotify"] = spotify
        let tm = makeManager(resolver: resolver)
        tm.selectedTargetID = "spotify"

        await tm.route(.volumeUp)
        XCTAssertTrue(spotify.performedCommands.isEmpty)
    }

    func testDirectRouteForwardsToBundleWithoutChangingHookedTarget() async {
        let resolver = MockResolver()
        let spotify = MockMediaApp(id: "spotify", isRunning: true)
        let music = MockMediaApp(id: "music", isRunning: true)
        resolver.apps["spotify"] = spotify
        resolver.apps["music"] = music
        let tm = makeManager(resolver: resolver)
        tm.selectedTargetID = "spotify"

        await tm.route(.playPause, toBundleID: music.bundleID)

        XCTAssertEqual(music.performedCommands, [.playPause])
        XCTAssertTrue(spotify.performedCommands.isEmpty)
        XCTAssertEqual(tm.selectedTargetID, "spotify")
    }

    func testDirectRouteNoOpForUnknownOrUnreadyBundle() async {
        let resolver = MockResolver()
        let music = MockMediaApp(id: "music", isRunning: true)
        music.readyValue = false
        resolver.apps["music"] = music
        let tm = makeManager(resolver: resolver)

        await tm.route(.playPause, toBundleID: "com.example.missing")
        await tm.route(.playPause, toBundleID: music.bundleID)

        XCTAssertTrue(music.performedCommands.isEmpty)
    }

    // MARK: - adjustVolume

    private func makeVolumeTarget(current: Int?, running: Bool = true) -> (MockResolver, MockMediaApp) {
        let resolver = MockResolver()
        let app = MockMediaApp(id: "spotify", isRunning: running)
        app.supportsVolume = true
        app.volumeValue = current
        resolver.apps["spotify"] = app
        return (resolver, app)
    }

    func testAdjustVolumeStepsUpFromCurrent() async {
        let (resolver, app) = makeVolumeTarget(current: 50)
        let tm = makeManager(resolver: resolver, volumeStep: 6)
        tm.selectedTargetID = "spotify"

        let result = await tm.adjustVolume(bySteps: 2)   // +12
        XCTAssertEqual(result?.volume, 62)
        XCTAssertEqual(result?.bundleID, "com.example.spotify")
        XCTAssertEqual(app.setVolumeCalls, [62])
    }

    func testAdjustVolumeStepsDown() async {
        let (resolver, app) = makeVolumeTarget(current: 50)
        let tm = makeManager(resolver: resolver, volumeStep: 6)
        tm.selectedTargetID = "spotify"

        let result = await tm.adjustVolume(bySteps: -3)   // -18
        XCTAssertEqual(result?.volume, 32)
        XCTAssertEqual(app.setVolumeCalls, [32])
    }

    func testAdjustVolumeClampsToBounds() async {
        let (resolver, app) = makeVolumeTarget(current: 95)
        let tm = makeManager(resolver: resolver, volumeStep: 6)
        tm.selectedTargetID = "spotify"

        let result = await tm.adjustVolume(bySteps: 5)   // +30 → clamp 100
        XCTAssertEqual(result?.volume, 100)
        XCTAssertEqual(app.setVolumeCalls, [100])
    }

    func testAdjustVolumeNoOpForZeroSteps() async {
        let (resolver, app) = makeVolumeTarget(current: 50)
        let tm = makeManager(resolver: resolver)
        tm.selectedTargetID = "spotify"

        let result = await tm.adjustVolume(bySteps: 0)
        XCTAssertNil(result)
        XCTAssertTrue(app.setVolumeCalls.isEmpty)
    }

    func testAdjustVolumeNoOpWhenNotReady() async {
        let (resolver, app) = makeVolumeTarget(current: 50, running: true)
        app.readyValue = false   // running but still launching
        let tm = makeManager(resolver: resolver)
        tm.selectedTargetID = "spotify"

        let result = await tm.adjustVolume(bySteps: 2)
        XCTAssertNil(result)
        XCTAssertTrue(app.setVolumeCalls.isEmpty)
    }

    func testAdjustVolumeNoOpWhenVolumeUnsupported() async {
        let resolver = MockResolver()
        let app = MockMediaApp(id: "spotify", isRunning: true)
        app.supportsVolume = false
        app.volumeValue = 50
        resolver.apps["spotify"] = app
        let tm = makeManager(resolver: resolver)
        tm.selectedTargetID = "spotify"

        let result = await tm.adjustVolume(bySteps: 2)
        XCTAssertNil(result)
        XCTAssertTrue(app.setVolumeCalls.isEmpty)
    }
}
