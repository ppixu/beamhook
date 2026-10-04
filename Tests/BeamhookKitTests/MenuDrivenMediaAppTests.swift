import XCTest
@testable import BeamhookKit

final class MenuDrivenMediaAppTests: XCTestCase {
    private let iinaBundleID = "com.colliderli.iina"

    private func makeIINA(presser: MockMenuPresser, presence: MockPresence) -> MenuDrivenMediaApp? {
        MenuDrivenMediaApp(definition: BuiltInApps.iina, presser: presser, presence: presence)
    }

    func testPlayPausePressesThePlayPauseItemWhenRunning() throws {
        let presser = MockMenuPresser()
        let presence = MockPresence()
        presence.runningBundleIDs = [iinaBundleID]
        let app = try XCTUnwrap(makeIINA(presser: presser, presence: presence))

        app.perform(.playPause)

        XCTAssertEqual(presser.pressed.count, 1)
        XCTAssertEqual(presser.pressed.first?.bundleID, iinaBundleID)
        XCTAssertEqual(presser.pressed.first?.path, BuiltInApps.iina.menuControl?.playPause)
    }

    func testNextAndPreviousPressTheirOwnItems() throws {
        let presser = MockMenuPresser()
        let presence = MockPresence()
        presence.runningBundleIDs = [iinaBundleID]
        let app = try XCTUnwrap(makeIINA(presser: presser, presence: presence))

        app.perform(.next)
        app.perform(.previous)

        XCTAssertEqual(presser.pressed.map(\.path),
                       [BuiltInApps.iina.menuControl?.next, BuiltInApps.iina.menuControl?.previous].compactMap { $0 })
    }

    func testNothingIsPressedWhenTheAppIsNotRunning() throws {
        let presser = MockMenuPresser()
        let app = try XCTUnwrap(makeIINA(presser: presser, presence: MockPresence()))

        app.perform(.playPause)

        XCTAssertTrue(presser.pressed.isEmpty)
    }

    func testNothingIsPressedWhileTheAppIsStillLaunching() throws {
        // A launching app has no menu bar yet; pressing into it just fails slowly.
        let presser = MockMenuPresser()
        let presence = MockPresence()
        presence.runningBundleIDs = [iinaBundleID]
        presence.readyBundleIDs = []
        let app = try XCTUnwrap(makeIINA(presser: presser, presence: presence))

        app.perform(.playPause)

        XCTAssertTrue(presser.pressed.isEmpty)
    }

    func testCommandWithNoConfiguredItemIsIgnored() {
        let presser = MockMenuPresser()
        let presence = MockPresence()
        presence.runningBundleIDs = ["com.example.player"]
        let control = MenuControl(
            playPause: MenuItemPath(menuIndex: 1, menuTitles: ["Playback"], itemIndex: 0, itemTitles: ["Pause"]),
            next: nil, previous: nil,
            playingTitles: ["Pause"], pausedTitles: ["Resume"])
        let definition = AppDefinition.menuDriven(
            id: "example", displayName: "Example", bundleID: "com.example.player", control: control)
        let app = MenuDrivenMediaApp(definition: definition, presser: presser, presence: presence)

        app?.perform(.next)

        XCTAssertTrue(presser.pressed.isEmpty)
    }

    // MARK: - Play state, read from the item's own title

    func testPlayStateIsReadFromTheMenuItemTitle() throws {
        let presser = MockMenuPresser()
        let presence = MockPresence()
        presence.runningBundleIDs = [iinaBundleID]
        let app = try XCTUnwrap(makeIINA(presser: presser, presence: presence))

        // The item offers the action you can take next: "Pause" means it is playing.
        presser.cannedTitle = "Pause"
        XCTAssertEqual(app.isPlaying(), true)

        presser.cannedTitle = "Resume"
        XCTAssertEqual(app.isPlaying(), false)
    }

    func testPlayStateToleratesWhitespaceAndCase() throws {
        let presser = MockMenuPresser()
        let presence = MockPresence()
        presence.runningBundleIDs = [iinaBundleID]
        let app = try XCTUnwrap(makeIINA(presser: presser, presence: presence))

        presser.cannedTitle = "  pause "
        XCTAssertEqual(app.isPlaying(), true)
    }

    func testUnrecognisedTitleReportsUnknownRatherThanGuessing() throws {
        // A localized IINA shows e.g. "Keskeytä"; transport still works by index,
        // but the state is genuinely unknown and must not be reported as paused.
        let presser = MockMenuPresser()
        let presence = MockPresence()
        presence.runningBundleIDs = [iinaBundleID]
        let app = try XCTUnwrap(makeIINA(presser: presser, presence: presence))

        presser.cannedTitle = "Keskeytä"
        XCTAssertNil(app.isPlaying())

        presser.cannedTitle = nil
        XCTAssertNil(app.isPlaying())
    }

    func testPlayStateIsUnknownWhenNotRunning() throws {
        let presser = MockMenuPresser()
        presser.cannedTitle = "Pause"
        let app = try XCTUnwrap(makeIINA(presser: presser, presence: MockPresence()))

        XCTAssertNil(app.isPlaying())
    }

    // MARK: - Volume

    func testVolumeIsUnsupported() throws {
        // Menu items only step the volume; there is no absolute set, so the app
        // reports no volume support and the UI hides the slider.
        let presser = MockMenuPresser()
        let presence = MockPresence()
        presence.runningBundleIDs = [iinaBundleID]
        let app = try XCTUnwrap(makeIINA(presser: presser, presence: presence))

        XCTAssertFalse(app.supportsVolume)
        XCTAssertNil(app.currentVolume())
        app.setVolume(50)
        XCTAssertTrue(presser.pressed.isEmpty)
    }

    // MARK: - Registry wiring

    func testShippedMenuDrivenTargets() {
        let menuDriven = BuiltInApps.all.filter { $0.menuControl != nil }.map(\.id)
        XCTAssertEqual(menuDriven, ["iina", "amazon-music", "plexamp", "deezer", "podcasts"])
    }

    func testRegistryResolvesMenuDrivenDefinitionsToMenuDrivenApps() {
        let presence = MockPresence()
        presence.runningBundleIDs = ["com.amazon.music", "com.spotify.client"]
        let registry = AppRegistry(store: AppDefinitionStore(defaults: emptyDefaults()),
                                   executor: MockScriptExecutor(),
                                   presser: MockMenuPresser(),
                                   presence: presence)

        XCTAssertTrue(registry.app(withID: BuiltInApps.amazonMusic.id) is MenuDrivenMediaApp)
        XCTAssertTrue(registry.app(withID: BuiltInApps.spotify.id) is ScriptedMediaApp)
    }

    private func emptyDefaults() -> UserDefaults {
        let defaults = UserDefaults(suiteName: "MenuDrivenMediaAppTests")!
        defaults.removePersistentDomain(forName: "MenuDrivenMediaAppTests")
        return defaults
    }

    // MARK: - Podcasts skip items

    private func podcastsApp(presser: MockMenuPresser) -> MenuDrivenMediaApp {
        let presence = MockPresence()
        presence.runningBundleIDs = ["com.apple.podcasts"]
        return MenuDrivenMediaApp(definition: BuiltInApps.podcasts, presser: presser, presence: presence)!
    }

    func testPodcastsAlwaysReportsAPodcastAndSeeksByMenu() {
        let app = podcastsApp(presser: MockMenuPresser())
        XCTAssertTrue(app.canSeek)
        XCTAssertTrue(app.seeksByMenu)
        XCTAssertEqual(app.playbackKind(), .podcast)
    }

    func testSeekPressesSkipForwardOrRewindByDirection() {
        let presser = MockMenuPresser()
        let app = podcastsApp(presser: presser)
        XCTAssertTrue(app.seek(by: 30))
        XCTAssertTrue(app.seek(by: -15))
        XCTAssertEqual(presser.pressed.map(\.path.itemIndex), [3, 4])
        XCTAssertTrue(presser.pressed[0].path.itemTitles.contains("Skip 30 sec"))
        XCTAssertTrue(presser.pressed[1].path.itemTitles.contains("Rewind 15 sec"))
        XCTAssertEqual(presser.pressed.map(\.bundleID), ["com.apple.podcasts", "com.apple.podcasts"])
    }

    func testMenuAppsWithoutSkipItemsCannotSeek() {
        let presence = MockPresence()
        presence.runningBundleIDs = [BuiltInApps.iina.bundleID]
        let presser = MockMenuPresser()
        let app = MenuDrivenMediaApp(definition: BuiltInApps.iina, presser: presser, presence: presence)!
        XCTAssertFalse(app.canSeek)
        XCTAssertFalse(app.seek(by: 15))
        XCTAssertTrue(presser.pressed.isEmpty)
    }

    func testPodcastsIsABuiltInTarget() {
        XCTAssertTrue(BuiltInApps.all.contains { $0.id == "podcasts" })
    }
}
