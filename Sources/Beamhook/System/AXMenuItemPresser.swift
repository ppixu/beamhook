import AppKit
import ApplicationServices
import BeamhookKit

/// Drives an app that has no AppleScript dictionary by pressing items in its own
/// menu bar over the Accessibility API — the same trick BeardedSpice uses for the
/// Electron players. The target is never activated and the menu never opens on
/// screen: `AXPress` on a menu item runs that item's action directly.
///
/// Every call blocks until the other app answers its Accessibility request, so
/// this must run on the `ScriptRunner` queue like AppleScript does — never main.
///
/// Needs the Accessibility permission, which Beamhook already holds for the media
/// key tap, so there is no second grant to ask the user for.
final class AXMenuItemPresser: MenuItemPressing {
    func press(_ path: MenuItemPath, bundleID: String) -> Bool {
        guard let item = copyItem(path, bundleID: bundleID) else { return false }
        return AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
    }

    func title(of path: MenuItemPath, bundleID: String) -> String? {
        guard let item = copyItem(path, bundleID: bundleID) else { return nil }
        return copyValue(item, kAXTitleAttribute) as? String
    }

    // MARK: - Menu-bar walk

    /// menu bar → the wanted menu-bar item → its single AXMenu → the wanted item.
    private func copyItem(_ path: MenuItemPath, bundleID: String) -> AXUIElement? {
        guard let app = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID).first else { return nil }

        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        guard let menuBar = copyValue(axApp, kAXMenuBarAttribute) else { return nil }
        let barItems = children(menuBar as! AXUIElement)

        if let barItem = match(in: barItems, titles: path.menuTitles, index: path.menuIndex) {
            // A menu-bar item owns exactly one AXMenu; that is where items live.
            guard let menu = children(barItem).first else { return nil }
            return match(in: children(menu), titles: path.itemTitles, index: path.itemIndex)
        }

        // No menu identified: hunt for the item by title across the whole bar. This
        // is the path for apps whose layout has not been mapped.
        guard !path.itemTitles.isEmpty else { return nil }
        for barItem in barItems {
            guard let menu = children(barItem).first else { continue }
            if let hit = match(in: children(menu), titles: path.itemTitles, index: nil) {
                return hit
            }
        }
        return nil
    }

    /// Title first so a reordered menu still resolves, index second so a localized
    /// menu does too. Returns nil when neither is available.
    private func match(in elements: [AXUIElement], titles: [String], index: Int?) -> AXUIElement? {
        if !titles.isEmpty {
            let wanted = Set(titles.map { $0.lowercased() })
            if let hit = elements.first(where: { element in
                guard let title = copyValue(element, kAXTitleAttribute) as? String else { return false }
                return wanted.contains(title.trimmingCharacters(in: .whitespaces).lowercased())
            }) {
                return hit
            }
        }
        guard let index, elements.indices.contains(index) else { return nil }
        return elements[index]
    }

    private func children(_ element: AXUIElement) -> [AXUIElement] {
        (copyValue(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }

    private func copyValue(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value
    }
}
