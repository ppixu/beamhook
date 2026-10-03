import Foundation

/// What the media-key tap does with a volume or mute key. The whole key table
/// lives here so `MediaKeyTap` asks one question instead of branching inline:
///
/// | Keys        | Hook ON                         | Hook OFF                  |
/// |-------------|---------------------------------|---------------------------|
/// | Vol         | handle                          | pass through              |
/// | ⌘ + Vol     | pass through, minus ⌘           | handle (target has volume)|
/// | Mute        | pass through                    | pass through              |
/// | ⌘ + Mute    | handle (target has volume)      | same                      |
///
/// While a volume session is active (the source list is on screen), every
/// volume key and ⌘ + Mute is handled, so a user still holding ⌘ after picking
/// a source doesn't fall through to the system volume.
public enum VolumeKeyAction: Equatable, Sendable {
    /// Swallow the event and hand the key to Beamhook.
    case handle
    /// Let macOS have the event unchanged.
    case passThrough
    /// Let macOS have it with ⌘ removed, so it lands as an ordinary volume key
    /// rather than a modified shortcut.
    case passThroughWithoutCommand

    /// - Parameters:
    ///   - key: the decoded media key. Anything but volume up/down and mute passes through.
    ///   - commandHeld: ⌘ is down.
    ///   - hijacked: the user turned the volume hook on for the hooked target.
    ///   - targetHasVolume: the hooked target's volume can be set right now.
    ///   - sessionActive: the source list is on screen.
    public static func resolve(key: MediaKey, commandHeld: Bool, hijacked: Bool,
                               targetHasVolume: Bool, sessionActive: Bool) -> VolumeKeyAction {
        switch key {
        case .mute:
            guard commandHeld, targetHasVolume || sessionActive else { return .passThrough }
            return .handle
        case .volumeUp, .volumeDown:
            if sessionActive { return .handle }
            if hijacked { return commandHeld ? .passThroughWithoutCommand : .handle }
            return commandHeld && targetHasVolume ? .handle : .passThrough
        default:
            return .passThrough
        }
    }
}
