import XCTest
@testable import BeamhookKit

final class MenuBarGlyphTests: XCTestCase {
    func testBadgedTargets() {
        XCTAssertEqual(MenuBarGlyph.forTarget(id: BuiltInApps.spotify.id), .spotify)
        XCTAssertEqual(MenuBarGlyph.forTarget(id: BuiltInApps.music.id), .appleMusic)
        XCTAssertEqual(MenuBarGlyph.forTarget(id: BuiltInApps.safariYouTube.id), .safari)
        XCTAssertEqual(MenuBarGlyph.forTarget(id: BuiltInApps.chromeYouTube.id), .chrome)
    }

    func testUnbadgedTargetsFallBackToThePlainHook() {
        // Everything we ship no art for, plus the browsers deliberately left plain:
        // Brave/Arc/Vivaldi are separate browsers and must not wear Chrome's mark.
        for id in [BuiltInApps.vlc.id, BuiltInApps.vox.id, BuiltInApps.appleTV.id,
                   BuiltInApps.quickTime.id, BuiltInApps.downcast.id,
                   BuiltInApps.braveYouTube.id, BuiltInApps.arcYouTube.id,
                   BuiltInApps.vivaldiYouTube.id] {
            XCTAssertEqual(MenuBarGlyph.forTarget(id: id), .hook, "id: \(id)")
        }
    }

    func testNothingHookedAndUserAddedAppsUseThePlainHook() {
        XCTAssertEqual(MenuBarGlyph.forTarget(id: nil), .hook)
        XCTAssertEqual(MenuBarGlyph.forTarget(id: "some.user.added.app"), .hook)
    }

    func testYouTubeTabOutranksItsBrowser() {
        XCTAssertEqual(
            MenuBarGlyph.forTarget(id: BuiltInApps.safariYouTube.id, browserHost: "www.youtube.com"),
            .youtube)
        // Brave has no browser art, so YouTube is the only badge it can earn.
        XCTAssertEqual(
            MenuBarGlyph.forTarget(id: BuiltInApps.braveYouTube.id, browserHost: "youtube.com"),
            .youtube)
    }

    func testNonYouTubeTabKeepsTheBrowserBadge() {
        XCTAssertEqual(
            MenuBarGlyph.forTarget(id: BuiltInApps.safariYouTube.id, browserHost: "vimeo.com"),
            .safari)
        XCTAssertEqual(
            MenuBarGlyph.forTarget(id: BuiltInApps.chromeYouTube.id, browserHost: ""),
            .chrome)
    }

    func testYouTubeHostVariants() {
        for host in ["youtube.com", "www.youtube.com", "m.youtube.com",
                     "music.youtube.com", "youtu.be", "YouTube.com",
                     "WWW.YouTube.Com", "www.youtube.com."] {
            XCTAssertTrue(MenuBarGlyph.isYouTube(host: host), "host: \(host)")
        }
    }

    func testLookalikeHostsDoNotMatch() {
        // The trap a `contains("youtube.com")` check would fall into.
        for host in ["notyoutube.com", "youtube.com.evil.example", "myyoutube.com",
                     "youtube.co", "fakeyoutu.be", "", "vimeo.com"] {
            XCTAssertFalse(MenuBarGlyph.isYouTube(host: host), "host: \(host)")
        }
    }

    func testAssetNamesAreUniqueAndNamespaced() {
        let names = MenuBarGlyph.allCases.map(\.rawValue)
        XCTAssertEqual(Set(names).count, names.count)
        XCTAssertTrue(names.allSatisfy { $0.hasPrefix("MenuBarIcon") })
    }
}
