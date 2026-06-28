import Foundation

public struct AppDefinition: Codable, Identifiable, Equatable {
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

    public init(id: String, displayName: String, bundleID: String, isBuiltIn: Bool,
                playPauseScript: String, nextScript: String?, previousScript: String?,
                volumeScaleKind: VolumeScaleKind, volumeGetScript: String?, volumeSetScript: String?,
                playStateScript: String? = nil) {
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
    }
}
