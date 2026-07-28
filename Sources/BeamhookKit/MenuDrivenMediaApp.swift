import Foundation

/// A target driven by pressing its own menu items instead of by AppleScript, for
/// apps that ship no scripting dictionary (IINA, and the Electron players).
///
/// Immutable after init and its collaborators are stateless, so it is safe to hand
/// to `ScriptRunning.run` — which is required, since every call blocks on the other
/// app answering an Accessibility request.
public final class MenuDrivenMediaApp: MediaApp, @unchecked Sendable {
    public let definition: AppDefinition
    private let control: MenuControl
    private let presser: MenuItemPressing
    private let presence: AppPresenceChecking

    /// Fails when the definition carries no `menuControl`, so a scripted definition
    /// can never be silently driven as a menu one.
    public init?(definition: AppDefinition, presser: MenuItemPressing, presence: AppPresenceChecking) {
        guard let control = definition.menuControl else { return nil }
        self.definition = definition
        self.control = control
        self.presser = presser
        self.presence = presence
    }

    public var id: String { definition.id }
    public var displayName: String { definition.displayName }
    public var bundleID: String { definition.bundleID }
    public var isRunning: Bool { presence.isRunning(bundleID: definition.bundleID) }
    public var isReady: Bool { presence.isReady(bundleID: definition.bundleID) }

    public func perform(_ command: MediaCommand) {
        // A launching app has no menu bar yet, so the lookup would only fail slowly.
        guard isReady else { return }
        let path: MenuItemPath?
        switch command {
        case .playPause: path = control.playPause
        case .next:      path = control.next
        case .previous:  path = control.previous
        }
        guard let path else { return }
        _ = presser.press(path, bundleID: definition.bundleID)
    }

    /// Menus only step the volume up and down; there is no absolute set to map onto
    /// a slider, so these targets report no volume support.
    public var supportsVolume: Bool { false }
    public func currentVolume() -> Int? { nil }
    public func setVolume(_ percent: Int) {}

    /// Reads the play/pause item's own title: a media player labels it with the
    /// action you can take next, so "Pause" means it is playing.
    public func isPlaying() -> Bool? {
        guard isReady, let raw = presser.title(of: control.playPause, bundleID: definition.bundleID) else {
            return nil
        }
        let title = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if control.playingTitles.contains(where: { $0.lowercased() == title }) { return true }
        if control.pausedTitles.contains(where: { $0.lowercased() == title }) { return false }
        // Localized title we don't know: unknown beats guessing, since the caller
        // renders this straight onto the play/pause button.
        return nil
    }
}
