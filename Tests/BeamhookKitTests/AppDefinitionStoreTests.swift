import XCTest
@testable import BeamhookKit

final class AppDefinitionStoreTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let suite = "AppDefinitionStoreTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    func testBuiltInsArePresent() {
        let ids = BuiltInApps.all.map { $0.id }
        XCTAssertTrue(ids.contains("spotify"))
        XCTAssertTrue(ids.contains("music"))
        XCTAssertTrue(ids.contains("vlc"))
        XCTAssertTrue(ids.contains("vox"))
        XCTAssertTrue(BuiltInApps.all.allSatisfy { $0.isBuiltIn })
    }

    func testRoundTripUserDefined() {
        let store = AppDefinitionStore(defaults: makeDefaults())
        XCTAssertEqual(store.loadUserDefined().count, 0)

        let custom = AppDefinition(
            id: "custom-1", displayName: "My Player", bundleID: "com.example.player",
            isBuiltIn: false,
            playPauseScript: "tell application \"My Player\" to playpause",
            nextScript: nil, previousScript: nil,
            volumeScaleKind: .none, volumeGetScript: nil, volumeSetScript: nil)
        store.saveUserDefined([custom])

        let loaded = store.loadUserDefined()
        XCTAssertEqual(loaded, [custom])
    }

    func testCorruptDataReturnsEmpty() {
        let d = makeDefaults()
        d.set(Data("not json".utf8), forKey: "userDefinedApps")
        let store = AppDefinitionStore(defaults: d)
        XCTAssertEqual(store.loadUserDefined(), [])
    }

    func testAllDefinitionsCombinesBuiltInAndUserDefined() {
        let store = AppDefinitionStore(defaults: makeDefaults())
        let custom = AppDefinition(
            id: "custom-1", displayName: "My Player", bundleID: "com.example.player",
            isBuiltIn: false, playPauseScript: "x",
            nextScript: nil, previousScript: nil,
            volumeScaleKind: .none, volumeGetScript: nil, volumeSetScript: nil)
        store.saveUserDefined([custom])

        let all = store.allDefinitions()
        XCTAssertEqual(all.count, BuiltInApps.all.count + 1)
        XCTAssertEqual(all.last, custom)
    }
}
