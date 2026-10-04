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
                             runner: ScriptRunning = InlineScriptRunner(),
                             volumeStep: Int = 6) -> TargetManager {
        TargetManager(defaults: defaults ?? makeDefaults(), resolver: resolver,
                      runner: runner, volumeStep: volumeStep)
    }

    func testFailedCommandsPropagateThroughBothRoutes() async {
        let resolver = MockResolver()
        let app = MockMediaApp(id: "music", isRunning: true)
        app.commandSucceeds = false
        resolver.apps[app.id] = app
        let manager = makeManager(resolver: resolver)
        manager.selectedTargetID = app.id
        let targetResult = await manager.route(.playPause)
        let rowResult = await manager.route(.playPause, toBundleID: app.bundleID)
        XCTAssertFalse(targetResult)
        XCTAssertFalse(rowResult)
        XCTAssertEqual(app.performedCommands.count, 2)
    }

    func testTrackKeysRunMusicScriptsWithoutTouchingSpotify() async {
        final class Resolver: MediaAppResolver {
            let apps: [MediaApp]
            init(_ apps: [MediaApp]) { self.apps = apps }
            func app(withID id: String) -> MediaApp? { apps.first { $0.id == id } }
            func allApps() -> [MediaApp] { apps }
        }
        let presence = MockPresence()
        presence.runningBundleIDs = [BuiltInApps.music.bundleID, BuiltInApps.spotify.bundleID,
                                      BuiltInApps.quickTime.bundleID]
        let musicExecutor = MockScriptExecutor()
        let spotifyExecutor = MockScriptExecutor()
        let quickTimeExecutor = MockScriptExecutor()
        let music = ScriptedMediaApp(definition: BuiltInApps.music, executor: musicExecutor, presence: presence)
        let spotify = ScriptedMediaApp(definition: BuiltInApps.spotify, executor: spotifyExecutor, presence: presence)
        let quickTime = ScriptedMediaApp(definition: BuiltInApps.quickTime, executor: quickTimeExecutor, presence: presence)
        let manager = makeManager(resolver: Resolver([music, spotify, quickTime]))
        manager.selectedTargetID = music.id
        for key in [MediaKey.next, .previous, .fastForward, .rewind] {
            let result = await manager.route(key)
            XCTAssertTrue(result)
        }
        XCTAssertEqual(musicExecutor.ranScripts, [
            "tell application \"Music\" to next track",
            "tell application \"Music\" to previous track",
            "tell application \"Music\" to next track",
            "tell application \"Music\" to previous track"
        ])
        // Unsupported commands and denied access must not fall back to Spotify.
        manager.selectedTargetID = quickTime.id
        for key in [MediaKey.next, .previous, .fastForward, .rewind] {
            let result = await manager.route(key)
            XCTAssertFalse(result)
        }
        XCTAssertTrue(quickTimeExecutor.ranScripts.isEmpty)
        manager.selectedTargetID = music.id
        musicExecutor.succeed = false
        let denied = await manager.route(.next)
        XCTAssertFalse(denied)
        XCTAssertTrue(spotifyExecutor.ranScripts.isEmpty)
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

        let routed = await tm.route(.playPause)
        XCTAssertTrue(routed)
        XCTAssertEqual(spotify.performedCommands, [.playPause])
    }

    func testRouteChecksReadinessWhenQueuedCommandActuallyRuns() async {
        let resolver = MockResolver()
        let spotify = MockMediaApp(id: "spotify", isRunning: true)
        spotify.readyValue = false
        resolver.apps["spotify"] = spotify
        let runner = BeforeRunScriptRunner { spotify.readyValue = true }
        let tm = makeManager(resolver: resolver, runner: runner)
        tm.selectedTargetID = "spotify"

        let routed = await tm.route(.playPause)

        XCTAssertTrue(routed)
        XCTAssertEqual(spotify.performedCommands, [.playPause])
    }

    func testRouteNoOpWhenTargetNotRunning() async {
        let resolver = MockResolver()
        let spotify = MockMediaApp(id: "spotify", isRunning: false)
        resolver.apps["spotify"] = spotify
        let tm = makeManager(resolver: resolver)
        tm.selectedTargetID = "spotify"

        let routed = await tm.route(.playPause)
        XCTAssertFalse(routed)
        XCTAssertTrue(spotify.performedCommands.isEmpty)
    }

    func testRouteNoOpWhenNoTargetSelected() async {
        let resolver = MockResolver()
        let spotify = MockMediaApp(id: "spotify", isRunning: true)
        resolver.apps["spotify"] = spotify
        let tm = makeManager(resolver: resolver)

        let routed = await tm.route(.playPause)
        XCTAssertFalse(routed)
        XCTAssertTrue(spotify.performedCommands.isEmpty)
    }

    func testRouteNoOpWhenTargetIDUnresolvable() async {
        let resolver = MockResolver()
        let spotify = MockMediaApp(id: "spotify", isRunning: true)
        resolver.apps["spotify"] = spotify
        let tm = makeManager(resolver: resolver)
        tm.selectedTargetID = "defunct-app"   // not registered in the resolver
        let routed = await tm.route(.playPause)
        XCTAssertFalse(routed)
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

        let routed = await tm.route(.playPause, toBundleID: music.bundleID)

        XCTAssertTrue(routed)
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

        let missing = await tm.route(.playPause, toBundleID: "com.example.missing")
        let unready = await tm.route(.playPause, toBundleID: music.bundleID)

        XCTAssertFalse(missing)
        XCTAssertFalse(unready)
        XCTAssertTrue(music.performedCommands.isEmpty)
    }

    // MARK: - updateVolume (volume-key steps)

    private func makeVolumeTarget(current: Int?, running: Bool = true) -> (MockResolver, MockMediaApp) {
        let resolver = MockResolver()
        let app = MockMediaApp(id: "spotify", isRunning: running)
        app.supportsVolume = true
        app.volumeValue = current
        resolver.apps["spotify"] = app
        return (resolver, app)
    }

    func testUpdateVolumeStepsUpFromCurrent() async {
        let (resolver, app) = makeVolumeTarget(current: 50)
        let tm = makeManager(resolver: resolver, volumeStep: 6)
        tm.selectedTargetID = "spotify"

        let delta = 2 * tm.volumeStep   // +12
        let change = await tm.updateVolume { $0 + delta }
        XCTAssertEqual(change?.volume, 62)
        XCTAssertEqual(change?.bundleID, "com.example.spotify")
        XCTAssertEqual(app.setVolumeCalls, [62])
    }

    func testUpdateVolumeStepsDown() async {
        let (resolver, app) = makeVolumeTarget(current: 50)
        let tm = makeManager(resolver: resolver, volumeStep: 6)
        tm.selectedTargetID = "spotify"

        let delta = -3 * tm.volumeStep   // -18
        let change = await tm.updateVolume { $0 + delta }
        XCTAssertEqual(change?.volume, 32)
        XCTAssertEqual(app.setVolumeCalls, [32])
    }

    func testUpdateVolumeStepsClampToBounds() async {
        let (resolver, app) = makeVolumeTarget(current: 95)
        let tm = makeManager(resolver: resolver, volumeStep: 6)
        tm.selectedTargetID = "spotify"

        let delta = 5 * tm.volumeStep   // +30 → clamp 100
        let change = await tm.updateVolume { $0 + delta }
        XCTAssertEqual(change?.volume, 100)
        XCTAssertEqual(app.setVolumeCalls, [100])
    }

    func testUpdateVolumeNoOpWhenNotReady() async {
        let (resolver, app) = makeVolumeTarget(current: 50, running: true)
        app.readyValue = false   // running but still launching
        let tm = makeManager(resolver: resolver)
        tm.selectedTargetID = "spotify"

        let change = await tm.updateVolume { $0 + 12 }
        XCTAssertNil(change)
        XCTAssertTrue(app.setVolumeCalls.isEmpty)
    }

    func testUpdateVolumeNoOpWhenVolumeUnsupported() async {
        let resolver = MockResolver()
        let app = MockMediaApp(id: "spotify", isRunning: true)
        app.supportsVolume = false
        app.volumeValue = 50
        resolver.apps["spotify"] = app
        let tm = makeManager(resolver: resolver)
        tm.selectedTargetID = "spotify"

        let change = await tm.updateVolume { $0 + 12 }
        XCTAssertNil(change)
        XCTAssertTrue(app.setVolumeCalls.isEmpty)
    }

    // MARK: - updateVolume

    func testUpdateVolumeAppliesTransformAndReportsPrevious() async {
        let (resolver, app) = makeVolumeTarget(current: 40)
        let tm = makeManager(resolver: resolver)
        tm.selectedTargetID = "spotify"

        let change = await tm.updateVolume { _ in 0 }
        XCTAssertEqual(change, VolumeChange(bundleID: "com.example.spotify", previous: 40, volume: 0))
        XCTAssertEqual(app.setVolumeCalls, [0])
    }

    func testUpdateVolumeClamps() async {
        let (resolver, app) = makeVolumeTarget(current: 40)
        let tm = makeManager(resolver: resolver)
        tm.selectedTargetID = "spotify"

        let change = await tm.updateVolume { $0 + 500 }
        XCTAssertEqual(change?.volume, 100)
        XCTAssertEqual(app.setVolumeCalls, [100])
    }

    func testUpdateVolumeNoOpWithoutReadableVolume() async {
        let (resolver, app) = makeVolumeTarget(current: nil)
        let tm = makeManager(resolver: resolver)
        tm.selectedTargetID = "spotify"

        let change = await tm.updateVolume { $0 + 6 }
        XCTAssertNil(change)
        XCTAssertTrue(app.setVolumeCalls.isEmpty)
    }

    func testUpdateVolumeOfBundleIDLeavesTheHookedTargetAlone() async {
        let (resolver, spotify) = makeVolumeTarget(current: 50)
        let music = MockMediaApp(id: "music", isRunning: true)
        music.supportsVolume = true
        music.volumeValue = 20
        resolver.apps["music"] = music
        let tm = makeManager(resolver: resolver)
        tm.selectedTargetID = "spotify"

        let change = await tm.updateVolume(ofBundleID: "com.example.music") { $0 + 10 }
        XCTAssertEqual(change, VolumeChange(bundleID: "com.example.music", previous: 20, volume: 30))
        XCTAssertEqual(music.setVolumeCalls, [30])
        XCTAssertTrue(spotify.setVolumeCalls.isEmpty)
        XCTAssertEqual(tm.selectedTargetID, "spotify")
    }

    func testUpdateVolumeOfBundleIDNoOpForUnknownOrUnreadyApp() async {
        let resolver = MockResolver()
        let music = MockMediaApp(id: "music", isRunning: true)
        music.supportsVolume = true
        music.volumeValue = 20
        music.readyValue = false
        resolver.apps["music"] = music
        let tm = makeManager(resolver: resolver)

        let unknown = await tm.updateVolume(ofBundleID: "com.example.nope") { $0 + 10 }
        let unready = await tm.updateVolume(ofBundleID: "com.example.music") { $0 + 10 }
        XCTAssertNil(unknown)
        XCTAssertNil(unready)
        XCTAssertTrue(music.setVolumeCalls.isEmpty)
    }

    func testVolumeStepIsReadable() {
        let tm = makeManager(resolver: MockResolver(), volumeStep: 9)
        XCTAssertEqual(tm.volumeStep, 9)
    }

    // MARK: - Short skip

    private final class SeekResolver: MediaAppResolver {
        let app: MockSeekingApp
        init(_ app: MockSeekingApp) { self.app = app }
        func app(withID id: String) -> MediaApp? { id == app.id ? app : nil }
        func allApps() -> [MediaApp] { [app] }
    }

    private func seekingManager(_ app: MockSeekingApp, defaults: UserDefaults? = nil) -> TargetManager {
        let manager = makeManager(resolver: SeekResolver(app), defaults: defaults)
        manager.selectedTargetID = app.id
        return manager
    }

    func testPodcastNextSkipsForwardAndPreviousSkipsBack() async {
        let app = MockSeekingApp(id: "pod")
        let manager = seekingManager(app)
        let forward = await manager.routeKey(.next)
        let back = await manager.routeKey(.previous)
        XCTAssertEqual(forward, .skipped(seconds: 15, byMenu: false))
        XCTAssertEqual(back, .skipped(seconds: -15, byMenu: false))
        XCTAssertEqual(app.seeks, [15, -15])
        XCTAssertTrue(app.performedCommands.isEmpty)
    }

    func testFailedSeekFallsBackToTheTrackCommand() async {
        let app = MockSeekingApp(id: "pod")
        app.seekSucceeds = false
        let outcome = await seekingManager(app).routeKey(.next)
        XCTAssertEqual(outcome, .performed(.next))
        XCTAssertEqual(app.performedCommands, [.next])
    }

    func testMusicKeepsTrackKeysUnlessAlwaysSkipIsOn() async {
        let app = MockSeekingApp(id: "spot")
        app.kind = .music
        let defaults = makeDefaults()
        let manager = seekingManager(app, defaults: defaults)
        let normal = await manager.routeKey(.next)
        XCTAssertEqual(normal, .performed(.next))
        TrackKeyPreference.setAlwaysSkip(true, in: defaults)
        let always = await manager.routeKey(.next)
        XCTAssertEqual(always, .skipped(seconds: 15, byMenu: false))
    }

    func testTurningTheSettingOffRestoresTrackKeys() async {
        let app = MockSeekingApp(id: "pod")
        let defaults = makeDefaults()
        TrackKeyPreference.setSkipOnPodcasts(false, in: defaults)
        let outcome = await seekingManager(app, defaults: defaults).routeKey(.next)
        XCTAssertEqual(outcome, .performed(.next))
        XCTAssertTrue(app.seeks.isEmpty)
    }

    func testPlayPauseNeverAsksForTheKind() async {
        let app = MockSeekingApp(id: "pod")
        let outcome = await seekingManager(app).routeKey(.playPause)
        XCTAssertEqual(outcome, .performed(.playPause))
        XCTAssertTrue(app.seeks.isEmpty)
    }

    func testRouteStillReportsDeliveryAsABool() async {
        let app = MockSeekingApp(id: "pod")
        let delivered = await seekingManager(app).route(.next)
        XCTAssertTrue(delivered)
    }
}

private final class BeforeRunScriptRunner: ScriptRunning {
    private let beforeRun: () -> Void

    init(_ beforeRun: @escaping () -> Void) {
        self.beforeRun = beforeRun
    }

    func run<T>(_ work: @escaping () -> T) async -> T {
        beforeRun()
        return work()
    }
}
