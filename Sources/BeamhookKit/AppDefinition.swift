import Foundation

public struct AppDefinition: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var displayName: String
    public var bundleID: String
    public let isBuiltIn: Bool
    public var playPauseScript: String
    public var nextScript: String?
    public var previousScript: String?
    public var volumeScaleKind: VolumeScaleKind
    public var volumeGetScript: String?
    public var volumeSetScript: String?   // must contain the token {volume}
    public var playStateScript: String?
    /// Set for apps with no AppleScript dictionary, which are driven by pressing
    /// their menu items instead. When present the scripts above are unused.
    /// Optional so definitions persisted before this existed still decode.
    public var menuControl: MenuControl?

    public init(id: String, displayName: String, bundleID: String, isBuiltIn: Bool,
                playPauseScript: String, nextScript: String?, previousScript: String?,
                volumeScaleKind: VolumeScaleKind, volumeGetScript: String?, volumeSetScript: String?,
                playStateScript: String? = nil, menuControl: MenuControl? = nil) {
        self.id = id
        self.displayName = displayName
        self.bundleID = bundleID
        self.isBuiltIn = isBuiltIn
        self.playPauseScript = playPauseScript
        self.nextScript = nextScript
        self.previousScript = previousScript
        self.volumeScaleKind = volumeScaleKind
        self.volumeGetScript = volumeGetScript
        self.volumeSetScript = volumeSetScript
        self.playStateScript = playStateScript
        self.menuControl = menuControl
    }

    /// A target with no scripting dictionary, driven through its menu bar. The
    /// script fields stay empty: `MenuDrivenMediaApp` never reads them.
    public static func menuDriven(id: String, displayName: String, bundleID: String,
                                  isBuiltIn: Bool = true, control: MenuControl) -> AppDefinition {
        AppDefinition(id: id, displayName: displayName, bundleID: bundleID, isBuiltIn: isBuiltIn,
                      playPauseScript: "", nextScript: nil, previousScript: nil,
                      volumeScaleKind: .none, volumeGetScript: nil, volumeSetScript: nil,
                      playStateScript: nil, menuControl: control)
    }
}
