import Foundation

/// Locates one item in another app's menu bar.
///
/// Two ways to find the same thing, because each fails differently: a title
/// survives a menu being reordered between app versions but breaks the moment the
/// user runs the app in another language, and an index does the opposite. Titles
/// are tried first and the index is the fallback, so a localized app still gets
/// working transport keys.
///
/// Both indices are optional, and that is a statement about evidence rather than a
/// convenience: an index is only ever written down when the position has actually
/// been observed. For an app whose menus nobody has mapped yet, leave them nil and
/// list the titles to hunt for — a definition should describe what to look for, not
/// assert a position that was never checked.
public struct MenuItemPath: Codable, Equatable, Sendable {
    /// Position in the menu bar, where index 0 is the Apple menu, so an app's own
    /// menu is 1. nil searches every menu for a matching item.
    public var menuIndex: Int?
    /// Titles this menu is known to use, in every localization we know of.
    public var menuTitles: [String]
    /// Position within that menu, counting separators. nil matches by title only.
    public var itemIndex: Int?
    /// Titles this item is known to use. A play/pause item alternates between two.
    public var itemTitles: [String]

    public init(menuIndex: Int?, menuTitles: [String], itemIndex: Int?, itemTitles: [String]) {
        self.menuIndex = menuIndex
        self.menuTitles = menuTitles
        self.itemIndex = itemIndex
        self.itemTitles = itemTitles
    }

    /// Finds the item purely by title, anywhere in the menu bar. For apps whose
    /// menu layout has not been mapped: it works if the titles are there and fails
    /// harmlessly if they are not.
    public static func search(itemTitles: [String]) -> MenuItemPath {
        MenuItemPath(menuIndex: nil, menuTitles: [], itemIndex: nil, itemTitles: itemTitles)
    }
}

/// How to drive an app that has no AppleScript dictionary: by pressing its own
/// menu items. The app never comes to the front and nothing is typed into it.
public struct MenuControl: Codable, Equatable, Sendable {
    public var playPause: MenuItemPath
    public var next: MenuItemPath?
    public var previous: MenuItemPath?
    /// Titles the play/pause item shows *while media plays* — it offers "Pause".
    public var playingTitles: [String]
    /// Titles it shows while paused — it offers "Resume" or "Play".
    public var pausedTitles: [String]

    public init(playPause: MenuItemPath, next: MenuItemPath?, previous: MenuItemPath?,
                playingTitles: [String], pausedTitles: [String]) {
        self.playPause = playPause
        self.next = next
        self.previous = previous
        self.playingTitles = playingTitles
        self.pausedTitles = pausedTitles
    }
}

/// Seam over the Accessibility API. Blocking, like `ScriptExecuting` — it waits on
/// the target app to answer, so it must run on a `ScriptRunning` queue, never main.
public protocol MenuItemPressing {
    /// Presses the item. False if it could not be found or the press was refused.
    func press(_ path: MenuItemPath, bundleID: String) -> Bool
    /// The item's current title, used to read play state. nil if unreadable.
    func title(of path: MenuItemPath, bundleID: String) -> String?
}
