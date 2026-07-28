import XCTest
import AppKit
@testable import BeamhookKit

/// `MenuBarGlyph`'s raw values name asset-catalog imagesets that
/// `Icon/make-icons.sh` generates. Nothing in the compiler ties the two together,
/// so a renamed case or a forgotten script run would ship a blank status item.
/// These tests run in the app host, so `NSImage(named:)` sees the real catalog.
final class MenuBarGlyphAssetTests: XCTestCase {
    func testEveryGlyphResolvesToABundledImage() {
        for glyph in MenuBarGlyph.allCases {
            XCTAssertNotNil(NSImage(named: glyph.rawValue),
                            "missing imageset for \(glyph): \(glyph.rawValue)")
        }
    }

    func testEveryGlyphIsATemplateImage() throws {
        // A non-template image would ignore the menu-bar tint and stay black on a
        // dark menu bar.
        for glyph in MenuBarGlyph.allCases {
            let image = try XCTUnwrap(NSImage(named: glyph.rawValue), "\(glyph)")
            XCTAssertTrue(image.isTemplate, "\(glyph) is not a template image")
        }
    }

    func testEveryGlyphIsSquareAndMenuBarSized() throws {
        for glyph in MenuBarGlyph.allCases {
            let image = try XCTUnwrap(NSImage(named: glyph.rawValue), "\(glyph)")
            XCTAssertEqual(image.size.width, image.size.height, "\(glyph) is not square")
            XCTAssertEqual(image.size.width, 18, "\(glyph) is not 18pt")
        }
    }
}
